#!/usr/bin/env bash
# ============================================================
# Techo 360 - Respaldo de bases de datos
# ------------------------------------------------------------
# Genera un dump comprimido de CADA UNA de las 3 bases de datos
# (principal, vectorial, usuarios) y conserva SOLO las ultimas 2
# copias de cada una (borra las mas antiguas automaticamente).
#
# Se puede correr manualmente o es llamado por los scripts de
# deploy antes de cada despliegue.
#
# Uso:
#   chmod +x backup-db.sh
#   ./scripts/backup-db.sh
# ============================================================

set -euo pipefail

LOCKFILE="/opt/techo360/backups/.backup.lock"
exec 200>"$LOCKFILE"
flock -w 60 200 || { echo "No se pudo obtener el lock de backup tras 60s, otro respaldo esta en curso"; exit 1; }

BACKUP_DIR="/opt/techo360/backups"

# Cargar variables de entorno (usuarios/contrasenas/nombres de las 3 BDs)
source /opt/techo360/techo360-infra/.env

mkdir -p "$BACKUP_DIR"

# Nombre de contenedor | usuario | nombre de BD | prefijo del archivo
DBS=(
  "techo360-postgres-principal|${DB_PRINCIPAL_USER}|${DB_PRINCIPAL_NAME}|principal"
  "techo360-postgres-vector|${DB_VECTOR_USER}|${DB_VECTOR_NAME}|vector"
  "techo360-postgres-users|${DB_USERS_USER}|${DB_USERS_NAME}|usuarios"
)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

for entry in "${DBS[@]}"; do
  IFS="|" read -r CONTAINER DBUSER DBNAME PREFIX <<< "$entry"
  FILE="$BACKUP_DIR/db_${PREFIX}_${TIMESTAMP}.sql.gz"

  echo "Generando respaldo de '$PREFIX' ($DBNAME): $FILE"
  docker exec "$CONTAINER" pg_dump -U "$DBUSER" "$DBNAME" | gzip > "$FILE"

  echo "Limpiando respaldos antiguos de '$PREFIX' (se conservan solo los ultimos 2)..."
  cd "$BACKUP_DIR"
  ls -1t db_${PREFIX}_*.sql.gz 2>/dev/null | tail -n +3 | xargs -r rm --
done

echo ""
echo "Respaldos actuales:"
ls -lh "$BACKUP_DIR"/db_*.sql.gz 2>/dev/null || echo "(ninguno aun)"
