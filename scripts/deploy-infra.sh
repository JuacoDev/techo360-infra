#!/usr/bin/env bash
# ============================================================
# Techo 360 - Despliegue de cambios de INFRAESTRUCTURA
# ------------------------------------------------------------
# A diferencia de deploy-service.sh (que toca un solo servicio),
# este script se usa cuando cambia el propio repo techo360-infra
# (docker-compose.yml, .env.example, limites de recursos, etc).
# Por naturaleza, un cambio de infra puede afectar a todos los
# servicios, asi que aqui SI se aplican los cambios a todos.
#
# No reconstruye las imagenes de codigo (eso lo hace cada
# deploy-service.sh individual) -- solo vuelve a aplicar la
# configuracion del docker-compose.yml actualizado.
#
# Lo llama el GitHub Actions del repo techo360-infra.
#
# Uso manual:
#   chmod +x deploy-infra.sh
#   ./scripts/deploy-infra.sh
# ============================================================

set -euo pipefail

PROJECT_DIR="/opt/techo360"
INFRA_DIR="$PROJECT_DIR/techo360-infra"
COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/deploy_infra_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Aplicando cambios de infraestructura: $(date) ==="

echo "--- 1. Respaldo de base de datos ---"
"$INFRA_DIR/scripts/backup-db.sh"

echo "--- 2. Actualizando el propio repo de infra ---"
cd "$INFRA_DIR"
git fetch origin
git checkout development
git reset --hard origin/development

echo "--- 3. Re-aplicando configuracion a todos los servicios ---"
echo "    (esto NO reconstruye codigo, solo aplica los cambios del"
echo "     docker-compose.yml: limites de recursos, variables, redes, etc.)"
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

echo "--- 4. Verificando que todos los contenedores esten arriba ---"
sleep 10
docker compose -f "$COMPOSE_FILE" ps

echo "--- 5. Usuario RabbitMQ del pool de workers (techo360-workers) ---"
if [ -n "${WORKER_RABBITMQ_PASSWORD:-}" ]; then
  chmod +x scripts/rabbitmq-worker-user.sh
  ./scripts/rabbitmq-worker-user.sh
else
  echo "    WORKER_RABBITMQ_PASSWORD no esta seteado en este run, se omite (no es un error: solo hace falta la primera vez o para rotar password)."
fi

echo "--- 6. Diagnostico de consumers de chatbot_requests (quien esta consumiendo y con que prioridad) ---"
docker exec techo360-rabbitmq rabbitmqctl list_consumers consumer_tag,queue_name,priority,active || true

echo "=== Cambios de infraestructura aplicados: $(date) ==="
echo "Revisa la salida de 'docker compose ps' arriba para confirmar que todo diga 'running'."
