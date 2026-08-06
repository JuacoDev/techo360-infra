#!/usr/bin/env bash
# ============================================================
# Techo 360 - Rollback de UN SOLO servicio
# ------------------------------------------------------------
# Revierte SOLO el servicio indicado a su commit anterior y
# reconstruye SOLO ese contenedor. Los demas servicios (incluida
# la base de datos) no se ven afectados.
#
# Se puede correr automaticamente (llamado por deploy-service.sh
# si el chequeo de salud falla) o manualmente.
#
# Uso:
#   chmod +x rollback-service.sh
#   ./scripts/rollback-service.sh backend
# ============================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: ./rollback-service.sh <backend|chatbot|proyeccion|frontend>"
  exit 1
fi

SERVICE="$1"
PROJECT_DIR="/opt/techo360"
INFRA_DIR="$PROJECT_DIR/techo360-infra"
COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"

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

echo "=== Iniciando rollback de: $SERVICE ($(date)) ==="

echo "--- 1. Volviendo $REPO_DIR al commit anterior ---"
cd "$REPO_DIR"
git reset --hard HEAD@{1}

echo "--- 2. Reconstruyendo SOLO $SERVICE con el codigo anterior ---"
cd "$INFRA_DIR"
docker compose -f "$COMPOSE_FILE" build "$SERVICE"

echo "--- 3. Reiniciando SOLO $SERVICE ---"
docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"

echo "=== Rollback de $SERVICE completado: $(date) ==="
