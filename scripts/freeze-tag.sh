#!/usr/bin/env bash
# ============================================================
# Techo 360 - Congelar version estable
# ------------------------------------------------------------
# Antes de una entrega/demo, congela las imagenes actuales de
# ":dev" bajo un nombre fijo, para que cambios de ultima hora
# en "development" no puedan romper la demo por accidente.
#
# Uso:
#   chmod +x freeze-tag.sh
#   ./scripts/freeze-tag.sh sprint1-demo
#
# Para usar la version congelada:
#   1. Edita .env y cambia TAG=dev por TAG=sprint1-demo
#   2. Corre: docker compose up -d
#
# Para volver a la version en desarrollo activo despues de la demo:
#   1. Edita .env y vuelve a poner TAG=dev
#   2. Corre: ./scripts/deploy.sh
# ============================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: ./freeze-tag.sh <nombre-etiqueta>"
  echo "Ejemplo: ./freeze-tag.sh sprint1-demo"
  exit 1
fi

TAG_NAME="$1"
SERVICES=("backend" "ai-service" "frontend")

echo "=== Congelando version actual como: $TAG_NAME ==="

for svc in "${SERVICES[@]}"; do
  docker tag "techo360/${svc}:dev" "techo360/${svc}:${TAG_NAME}"
  echo "  techo360/${svc}:dev  ->  techo360/${svc}:${TAG_NAME}"
done

echo ""
echo "Listo. Para usar esta version durante la demo:"
echo "  1. Edita .env y cambia TAG=dev por TAG=${TAG_NAME}"
echo "  2. Corre: docker compose up -d"
echo ""
echo "Para volver a desarrollo activo despues de la demo, vuelve TAG=dev y corre deploy.sh"
