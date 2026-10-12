#!/usr/bin/env bash
# Backup diario del CRM en la VM Oracle: dump lógico de Postgres + tar del
# storage local, a /opt/twenty/backups con retención de 30 días.
#
# Falla en voz alta (exit != 0 y una línea ERROR) ante cualquier problema. En el
# server anterior el cron produjo dumps de 0 bytes durante semanas porque el
# contenedor de la base estaba parado y nadie se enteró.
#
# Instalado por cron del usuario ubuntu (copiar el script a /opt/twenty primero):
#   15 3 * * * /opt/twenty/backup-twenty.sh >> /opt/twenty/backups/backup.log 2>&1
set -euo pipefail

ENV_FILE=/opt/twenty/.env
DEST=/opt/twenty/backups
KEEP_DAYS=30
DB_CONTAINER=twenty_db_oracle
STORAGE_VOLUME=twenty-oracle_twenty-storage-oracle
# Imagen ya presente en la VM (la usa el servicio db) y publicada para arm64;
# trae tar, así que el backup no depende de bajar nada de un registry.
TAR_IMAGE=postgres:16
STAMP=$(date +%Y%m%d-%H%M%S)

DB_FILE="$DEST/twenty-db-$STAMP.dump"
ST_FILE="$DEST/twenty-storage-$STAMP.tar.gz"

fail() {
  echo "[$(date -Is)] ERROR: $*" >&2
  exit 1
}

# Los archivos parciales se borran al salir con error: un backup a medias se
# vería igual que uno bueno hasta el día que lo necesitás.
BACKUP_OK=0
cleanup_on_exit() {
  if [ "$BACKUP_OK" -ne 1 ]; then
    rm -f "$DB_FILE" "$ST_FILE"
  fi
}
trap cleanup_on_exit EXIT

[ -f "$ENV_FILE" ] || fail "$ENV_FILE not found"

# A propósito NO hacemos `source` del .env: tiene valores con espacios
# (EMAIL_FROM_NAME) que el shell interpretaría como comando.
PG_USER=$(grep -E '^PG_DATABASE_USER=' "$ENV_FILE" | cut -d= -f2- || true)
PG_DB=$(grep -E '^PG_DATABASE_NAME=' "$ENV_FILE" | cut -d= -f2- || true)
[ -n "$PG_USER" ] && [ -n "$PG_DB" ] || fail "PG_DATABASE_USER / PG_DATABASE_NAME missing in $ENV_FILE"

mkdir -p "$DEST"

echo "[$(date -Is)] backup start"

[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2> /dev/null || true)" = "true" ] \
  || fail "container $DB_CONTAINER is not running; refusing to write an empty backup"

docker volume inspect "$STORAGE_VOLUME" > /dev/null 2>&1 \
  || fail "volume $STORAGE_VOLUME not found"

# -Fc = formato custom: comprimido y restaurable de forma selectiva (pg_restore
# permite sacar una sola tabla o un solo schema de workspace).
docker exec "$DB_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc > "$DB_FILE" \
  || fail "pg_dump failed"
[ -s "$DB_FILE" ] || fail "pg_dump produced an empty file"
docker exec -i "$DB_CONTAINER" pg_restore --list < "$DB_FILE" > /dev/null \
  || fail "dump failed pg_restore --list verification: $DB_FILE"

docker run --rm --entrypoint tar -v "$STORAGE_VOLUME":/data:ro -v "$DEST":/out \
  "$TAR_IMAGE" czf "/out/$(basename "$ST_FILE")" -C /data . \
  || fail "storage tar failed"
[ -s "$ST_FILE" ] || fail "storage tar produced an empty file"
tar tzf "$ST_FILE" > /dev/null || fail "storage tar failed verification: $ST_FILE"

BACKUP_OK=1

find "$DEST" -maxdepth 1 -name 'twenty-*' -mtime +"$KEEP_DAYS" -delete

echo "[$(date -Is)] backup ok — db=$(du -h "$DB_FILE" | cut -f1)" \
     "storage=$(du -h "$ST_FILE" | cut -f1) total=$(du -sh "$DEST" | cut -f1)"
