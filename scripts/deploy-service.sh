#!/usr/bin/env bash
# ============================================================
# Techo 360 - Despliegue de UN SOLO servicio
# ------------------------------------------------------------
# Este es el corazon del aislamiento de fallos: reconstruye y
# reinicia SOLO el servicio indicado (backend, chatbot, proyeccion
# o frontend), sin tocar los demas contenedores. Si algo sale mal,
# solo ese servicio se ve afectado.
#
# Uso: ./deploy-service.sh <backend|chatbot|proyeccion|frontend>
#   chmod +x deploy-service.sh
#   ./scripts/deploy-service.sh backend
# ============================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: ./deploy-service.sh <backend|chatbot|proyeccion|frontend>"
  exit 1
fi

SERVICE="$1"
PROJECT_DIR="/opt/techo360"
INFRA_DIR="$PROJECT_DIR/techo360-infra"
COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/deploy_${SERVICE}_$(date +%Y%m%d_%H%M%S).log"

# Mapeo de nombre de servicio -> carpeta del repo correspondiente
case "$SERVICE" in
  backend)     REPO_DIR="$PROJECT_DIR/techo360-backend" ;;
  chatbot)     REPO_DIR="$PROJECT_DIR/techo360-chatbot" ;;
  proyeccion)  REPO_DIR="$PROJECT_DIR/techo360-proyeccion" ;;
  frontend)    REPO_DIR="$PROJECT_DIR/techo360-frontend" ;;
  *)
    echo "Servicio desconocido: $SERVICE (usa backend, chatbot, proyeccion o frontend)"
    exit 1
    ;;
esac

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Desplegando servicio: $SERVICE ($(date)) ==="

echo "--- 1. Respaldo de base de datos (por seguridad, aunque este servicio no la toque directo) ---"
"$INFRA_DIR/scripts/backup-db.sh"

echo "--- 2. Actualizando codigo de $REPO_DIR ---"
cd "$REPO_DIR"
git fetch origin
git checkout development
git reset --hard origin/development

echo "--- 3. Reconstruyendo SOLO la imagen de $SERVICE ---"
cd "$INFRA_DIR"
docker compose -f "$COMPOSE_FILE" build "$SERVICE"

echo "--- 4. Reiniciando SOLO el contenedor de $SERVICE (los demas no se tocan) ---"
docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"

echo "--- 5. Verificando salud de $SERVICE (con reintentos) ---"
HEALTHY=false
for i in 1 2 3 4 5 6; do
  sleep 5
  if docker compose -f "$COMPOSE_FILE" ps --status running | grep -q "techo360-${SERVICE}"; then
    HEALTHY=true
    break
  fi
  echo "Intento $i: $SERVICE aun no responde, reintentando..."
done

if [ "$HEALTHY" = true ]; then
  echo "=== Deploy de $SERVICE completado con exito: $(date) ==="
else
  echo "!!! ERROR: $SERVICE no quedo arriba tras varios intentos. Mostrando estado actual: !!!"
  docker compose -f "$COMPOSE_FILE" ps
  echo "Ejecutando rollback SOLO de este servicio."
  "$INFRA_DIR/scripts/rollback-service.sh" "$SERVICE"
  exit 1
fi
