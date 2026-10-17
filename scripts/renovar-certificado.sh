#!/usr/bin/env bash
# ============================================================
# Techo 360 - Renovacion del certificado Let's Encrypt
# ------------------------------------------------------------
# Corre certbot en un contenedor efimero (reto HTTP-01 por webroot) y, SOLO si
# se renovo algun certificado, valida y recarga nginx del contenedor frontend
# (reload, no restart: no corta conexiones).
#
# Uso:
#   scripts/renovar-certificado.sh             # renovacion real (la llama cron)
#   scripts/renovar-certificado.sh --dry-run   # prueba contra el staging de Let's Encrypt
#
# Cron del usuario techo360-admin (dos veces al dia, Let's Encrypt lo recomienda):
#   17 3,15 * * * /opt/techo360/techo360-infra/scripts/renovar-certificado.sh >> /opt/techo360/logs/renovar-certificado.log 2>&1
#
# certbot solo renueva cuando faltan < 30 dias; el resto de las corridas no hace nada.
# Reversa: ver docs/certificado-letsencrypt.md.
# ============================================================
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="$INFRA_DIR/certbot"
MARCA="$CB/www/.renovado"          # la crea el deploy-hook de certbot (carpeta que SI escribe este usuario)
FRONTEND="techo360-frontend"

EXTRA=()
[ "${1:-}" = "--dry-run" ] && EXTRA=(--dry-run)

rm -f "$MARCA"
echo "=== Renovacion de certificado: $(date -u +%FT%TZ) ${EXTRA[*]:-} ==="
docker run --rm \
  -v "$CB/conf:/etc/letsencrypt" \
  -v "$CB/www:/var/www/certbot" \
  certbot/certbot renew --webroot -w /var/www/certbot \
  --deploy-hook "touch /var/www/certbot/.renovado" \
  --non-interactive "${EXTRA[@]}"

if [ -f "$MARCA" ]; then
  echo "--- Certificado renovado: validando y recargando nginx ---"
  docker exec "$FRONTEND" nginx -t
  docker exec "$FRONTEND" nginx -s reload
  rm -f "$MARCA"
  echo "--- nginx recargado ---"
else
  echo "--- Sin renovaciones (o --dry-run): nginx no se toca ---"
fi
