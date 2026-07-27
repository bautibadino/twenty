#!/usr/bin/env bash
# Backup diario del CRM: dump lógico de Postgres + tar del storage local.
#
# Complementa, no reemplaza, el snapshot de disco de Contabo. El snapshot
# restaura el VPS entero (y con él arrastra las tiendas WooCommerce a ese mismo
# punto en el tiempo); esto permite volver solo la base del CRM.
#
# Instalado por cron:
#   15 3 * * * /opt/twenty/src/deploy/vps/backup-twenty.sh >> /opt/twenty/backups/backup.log 2>&1
set -euo pipefail

ENV_FILE=/opt/twenty/.env
DEST=/opt/twenty/backups
KEEP_DAYS=30
STAMP=$(date +%Y%m%d-%H%M%S)

# A propósito NO hacemos `source` del .env: tiene valores con espacios
# (EMAIL_FROM_NAME=PymeInteligente CRM) que el shell interpretaría como comando.
PG_USER=$(grep -E '^PG_DATABASE_USER=' "$ENV_FILE" | cut -d= -f2-)
PG_DB=$(grep -E '^PG_DATABASE_NAME=' "$ENV_FILE" | cut -d= -f2-)

mkdir -p "$DEST"

DB_FILE="$DEST/twenty-db-$STAMP.dump"
ST_FILE="$DEST/twenty-storage-$STAMP.tar.gz"

echo "[$(date -Is)] backup start"

# -Fc = formato custom: comprimido y restaurable de forma selectiva (pg_restore
# permite sacar una sola tabla o un solo schema de workspace).
docker exec twenty_db pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$DB_FILE"

# Si el dump salió corrupto, pg_restore --list falla y el script corta acá.
# Sin esto, un backup inservible se vería igual que uno bueno hasta el día que
# lo necesitás.
docker exec -i twenty_db pg_restore --list > /dev/null < "$DB_FILE"

docker run --rm -v twenty_twenty-storage:/data -v "$DEST":/out alpine \
  tar czf "/out/$(basename "$ST_FILE")" -C /data .

find "$DEST" -maxdepth 1 -name 'twenty-*' -mtime +"$KEEP_DAYS" -delete

echo "[$(date -Is)] backup ok — db=$(du -h "$DB_FILE" | cut -f1)" \
     "storage=$(du -h "$ST_FILE" | cut -f1) total=$(du -sh "$DEST" | cut -f1)"
