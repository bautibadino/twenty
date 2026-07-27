#!/usr/bin/env bash
# Rebuild de la imagen + restart.
#
# Solo hace falta cuando cambia CÓDIGO. Para cambios de .env o del compose
# alcanza con `docker compose up -d server worker`, que tarda segundos.
#
# El build tarda bastante (decenas de minutos en 4 vCPU). Conviene lanzarlo así:
#   cd /opt/twenty/src && git pull --quiet && \
#     nohup deploy/vps/rebuild.sh > /opt/twenty/rebuild.log 2>&1 &
set -euo pipefail

SRC=/opt/twenty/src
DEST=/opt/twenty

cd "$SRC"
git pull --ff-only

echo "[$(date -Is)] build start"
docker build \
  --target twenty \
  -f packages/twenty-docker/twenty/Dockerfile \
  -t twenty-fork:latest .

echo "[$(date -Is)] build ok — aplicando compose y recreando"
cp deploy/vps/docker-compose.yml "$DEST/docker-compose.yml"

cd "$DEST"
docker compose up -d server worker

echo "[$(date -Is)] listo"
