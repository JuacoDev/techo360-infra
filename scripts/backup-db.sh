#!/usr/bin/env bash
# ============================================================
# Techo 360 - Respaldo de base de datos
# ------------------------------------------------------------
# Genera un dump comprimido de Postgres y conserva SOLO las
# ultimas 2 copias (borra las mas antiguas automaticamente).
#
# Se puede correr manualmente o es llamado por deploy.sh antes
# de cada despliegue.
#
# Uso:
#   chmod +x backup-db.sh
#   ./scripts/backup-db.sh
# ============================================================

set -euo pipefail

BACKUP_DIR="/opt/techo360/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/db_${TIMESTAMP}.sql.gz"
CONTAINER="techo360-postgres"

# Cargar variables de entorno (POSTGRES_USER, POSTGRES_DB)
source /opt/techo360/techo360-infra/.env

mkdir -p "$BACKUP_DIR"

echo "Generando respaldo: $FILE"
docker exec "$CONTAINER" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$FILE"
echo "Respaldo creado correctamente."

echo "Limpiando respaldos antiguos (se conservan solo los ultimos 2)..."
cd "$BACKUP_DIR"
ls -1t db_*.sql.gz 2>/dev/null | tail -n +3 | xargs -r rm --

echo "Respaldos actuales:"
ls -lh "$BACKUP_DIR"/db_*.sql.gz 2>/dev/null || echo "(ninguno aun)"
