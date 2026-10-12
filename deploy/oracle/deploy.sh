#!/usr/bin/env bash
# Deploys a prebuilt Twenty image on the Oracle VM (ARM64). Runs ON the server as
# the deploy user. CI streams it over SSH, so the server needs no git checkout:
#   ssh user@host 'bash -s -- <image-ref>' < deploy/oracle/deploy.sh
#
# Usage: deploy.sh <image-ref>   e.g. ghcr.io/bautibadino/twenty-fork:<sha>
#
# Flow: preconditions -> pull -> stop server and worker -> verified pre-deploy
# dump -> retag -> database upgrade with the NEW image -> start -> wait for
# healthy. The application is down from the stop until the new server is healthy.
# There is no automatic database restore: after a schema upgrade the dump taken
# here is the only way back, and restoring is a human decision.
set -euo pipefail

# Server-specific names. Everything else in the script is generic.
STACK_DIR=/opt/twenty
COMPOSE_FILE="$STACK_DIR/docker-compose.oracle.yml"
ENV_FILE="$STACK_DIR/.env"
DB_CONTAINER=twenty_db_oracle
SERVER_CONTAINER=twenty_server_oracle
LOCAL_IMAGE=twenty-fork
CURRENT_TAG=arm64
PREVIOUS_TAG=arm64-previous
HOST_HEALTH_URL=http://127.0.0.1:3000/healthz

BACKUP_DIR="$STACK_DIR/backups"
LOG_FILE="$STACK_DIR/deploy.log"
MIN_FREE_KB=$((8 * 1024 * 1024))
HEALTH_TIMEOUT_SECONDS=300
DUMP_RETENTION_DAYS=14

BACKUP_FILE=""
PREVIOUS_IMAGE_ID=""

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

compose() {
  # stdin is closed on purpose: this script itself is read from stdin when
  # streamed over SSH, and a docker child would swallow the rest of it.
  docker compose -f "$COMPOSE_FILE" --project-directory "$STACK_DIR" "$@" < /dev/null
}

warn_database_state() {
  log "WARNING: the database may be partially or fully upgraded."
  log "Pre-deploy dump (the only way back after a schema upgrade): ${BACKUP_FILE}"
  log "Restore steps: deploy/oracle/README.md, section 'Restaurar el dump pre-deploy'."
}

restore_previous_image() {
  if [ -z "$PREVIOUS_IMAGE_ID" ]; then
    log "no previous image was running before this deploy; nothing to roll back to"
    return 1
  fi
  docker tag "$PREVIOUS_IMAGE_ID" "${LOCAL_IMAGE}:${CURRENT_TAG}" < /dev/null
  log "tag ${LOCAL_IMAGE}:${CURRENT_TAG} restored to the previous image"
}

check_preconditions() {
  log "preconditions"
  docker info > /dev/null 2>&1 < /dev/null \
    || die "docker is not usable by $(id -un) (daemon down, or user not in the docker group)"
  docker compose version > /dev/null 2>&1 < /dev/null \
    || die "docker compose plugin not available"
  [ -f "$COMPOSE_FILE" ] || die "$COMPOSE_FILE not found"
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found"

  local free_kb
  free_kb=$(df -Pk "$STACK_DIR" | awk 'NR==2 {print $4}')
  if [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
    die "only $((free_kb / 1024 / 1024)) GB free on ${STACK_DIR}; need at least 8 GB for the image pull and the dump"
  fi

  [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2> /dev/null < /dev/null)" = "true" ] \
    || die "container ${DB_CONTAINER} is not running; refusing to deploy without a database to back up"
  log "preconditions ok (free: $((free_kb / 1024 / 1024)) GB)"
}

stop_application() {
  # The old code must not write while the dump is taken or while the schema is
  # being upgraded: writes after the dump would be lost on a restore.
  log "stopping server and worker"
  compose stop server worker
}

# Called under `if !`, where set -e is off: every failure needs an explicit
# return, so the caller can restart the application it just stopped.
backup_database() {
  log "pre-deploy database backup"

  # No `source` on the .env: it has values with spaces (EMAIL_FROM_NAME) that
  # the shell would run as commands. Same approach as backup-twenty.sh.
  local pg_user pg_db stamp
  pg_user=$(grep -E '^PG_DATABASE_USER=' "$ENV_FILE" | cut -d= -f2-)
  pg_db=$(grep -E '^PG_DATABASE_NAME=' "$ENV_FILE" | cut -d= -f2-)
  if [ -z "$pg_user" ] || [ -z "$pg_db" ]; then
    log "ERROR: PG_DATABASE_USER / PG_DATABASE_NAME missing in $ENV_FILE"
    return 1
  fi

  mkdir -p "$BACKUP_DIR" || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  BACKUP_FILE="$BACKUP_DIR/predeploy-${stamp}.dump"

  if ! docker exec "$DB_CONTAINER" pg_dump -U "$pg_user" -d "$pg_db" -Fc < /dev/null > "$BACKUP_FILE"; then
    rm -f "$BACKUP_FILE"
    log "ERROR: pg_dump failed"
    return 1
  fi
  if [ ! -s "$BACKUP_FILE" ]; then
    rm -f "$BACKUP_FILE"
    log "ERROR: pg_dump produced an empty file"
    return 1
  fi
  # A corrupt dump looks identical to a good one until the day it is needed.
  if ! docker exec -i "$DB_CONTAINER" pg_restore --list < "$BACKUP_FILE" > /dev/null; then
    log "ERROR: dump failed pg_restore --list verification: $BACKUP_FILE"
    return 1
  fi
  log "backup verified: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
}

pull_image() {
  local image_ref=$1
  log "pull ${image_ref}"

  PREVIOUS_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "${LOCAL_IMAGE}:${CURRENT_TAG}" 2> /dev/null < /dev/null || true)

  docker pull "$image_ref" < /dev/null
}

tag_image() {
  local image_ref=$1
  local new_image_id
  new_image_id=$(docker image inspect -f '{{.Id}}' "$image_ref" < /dev/null)

  # Skip when redeploying the same image, otherwise :${PREVIOUS_TAG} would point at
  # the build we are trying to leave.
  if [ -n "$PREVIOUS_IMAGE_ID" ] && [ "$PREVIOUS_IMAGE_ID" != "$new_image_id" ]; then
    docker tag "$PREVIOUS_IMAGE_ID" "${LOCAL_IMAGE}:${PREVIOUS_TAG}" < /dev/null
    log "kept running image as ${LOCAL_IMAGE}:${PREVIOUS_TAG}"
  fi
  docker tag "$image_ref" "${LOCAL_IMAGE}:${CURRENT_TAG}" < /dev/null
  log "tagged ${LOCAL_IMAGE}:${CURRENT_TAG} -> ${new_image_id}"
}

run_database_upgrade() {
  log "database upgrade with the new image"
  # Called under `if !`, where set -e is off: every failure needs an explicit
  # return.
  compose up -d --wait db redis || return 1

  # Sequence copied from packages/twenty-docker/twenty/entrypoint.sh
  # (setup_and_migrate_db): cache:flush, upgrade, cache:flush. `upgrade` is the
  # single entry point in v2.46: it runs fast instance, slow instance and then
  # workspace commands in order (packages/twenty-server/docs/UPGRADE_COMMANDS.md,
  # "Execution Order"; upgrade.command.ts). The old `run-instance-commands
  # --force --include-slow` only covers the instance part and skips workspaces.
  # `node dist/command/command` is what `yarn command:prod` expands to
  # (packages/twenty-server/package.json). The entrypoint downgrades an upgrade
  # failure to a warning; here it must be fatal.
  # DISABLE_CRON_JOBS_REGISTRATION: the entrypoint would otherwise register crons
  # for this one-off container.
  local run_upgrade=(
    docker compose -f "$COMPOSE_FILE" --project-directory "$STACK_DIR"
    run --rm --no-deps -T -e DISABLE_CRON_JOBS_REGISTRATION=true server
    node dist/command/command
  )

  "${run_upgrade[@]}" cache:flush < /dev/null \
    || log "warning: cache:flush before upgrade failed, continuing (same as entrypoint.sh)"

  local upgrade_log
  upgrade_log=$(mktemp)
  if ! "${run_upgrade[@]}" upgrade < /dev/null 2>&1 | tee "$upgrade_log"; then
    rm -f "$upgrade_log"
    return 1
  fi
  # Belt and braces: do not rely only on the exit code of the nest-commander CLI.
  if grep -q 'Upgrade failed:' "$upgrade_log"; then
    rm -f "$upgrade_log"
    return 1
  fi
  rm -f "$upgrade_log"

  "${run_upgrade[@]}" cache:flush < /dev/null \
    || log "warning: cache:flush after upgrade failed, continuing (same as entrypoint.sh)"
}

wait_until_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local status=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SERVER_CONTAINER" 2> /dev/null < /dev/null || echo missing)
    if [ "$status" = "healthy" ]; then
      # The reverse tunnel forwards exactly this host port, so the container
      # healthcheck alone does not prove that traffic can arrive.
      local attempt
      for attempt in 1 2 3 4 5 6; do
        if curl -fsS --max-time 10 "$HOST_HEALTH_URL" < /dev/null > /dev/null; then
          log "host health check ok: ${HOST_HEALTH_URL}"
          return 0
        fi
        sleep 5
      done
      log "container is healthy but ${HOST_HEALTH_URL} does not answer from the host"
      return 1
    fi
    sleep 5
  done
  log "last observed health status: ${status}"
  return 1
}

cleanup() {
  log "cleanup"
  local current_id previous_id ref ref_id
  current_id=$(docker image inspect -f '{{.Id}}' "${LOCAL_IMAGE}:${CURRENT_TAG}" < /dev/null)
  previous_id=$(docker image inspect -f '{{.Id}}' "${LOCAL_IMAGE}:${PREVIOUS_TAG}" 2> /dev/null < /dev/null || true)

  # Registry-tagged copies pile up one per deploy; keep only the current and
  # the previous image.
  while IFS= read -r ref; do
    ref_id=$(docker image inspect -f '{{.Id}}' "$ref" < /dev/null)
    if [ "$ref_id" != "$current_id" ] && [ "$ref_id" != "$previous_id" ]; then
      docker rmi "$ref" < /dev/null > /dev/null || true
    fi
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' < /dev/null | grep -E '^ghcr\.io/.+/twenty-fork:' || true)

  docker image prune -f < /dev/null > /dev/null || true
  find "$BACKUP_DIR" -maxdepth 1 -name 'predeploy-*.dump' -mtime +"$DUMP_RETENTION_DAYS" -delete
}

main() {
  if [ "$#" -ne 1 ]; then
    echo "usage: deploy.sh <image-ref>" >&2
    exit 2
  fi
  local image_ref=$1
  # The ref is interpolated into a remote command line by CI; reject anything
  # that is not a plain image reference.
  if ! [[ "$image_ref" =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$ ]]; then
    echo "invalid image reference: ${image_ref}" >&2
    exit 2
  fi

  log "deploy start: ${image_ref}"
  check_preconditions
  # Pull before stopping anything: it is the slow step and needs no downtime.
  pull_image "$image_ref"
  stop_application

  if ! backup_database; then
    log "ERROR: pre-deploy backup failed; nothing was changed, restarting the current version"
    compose up -d server worker || log "ERROR: could not restart server and worker"
    exit 1
  fi

  tag_image "$image_ref"

  if ! run_database_upgrade; then
    log "ERROR: database upgrade failed; the new containers were NOT started"
    if restore_previous_image; then
      compose up -d --force-recreate server worker || log "ERROR: could not restart with the previous image"
    fi
    warn_database_state
    exit 1
  fi

  log "starting server and worker"
  compose up -d server worker
  if ! wait_until_healthy; then
    log "ERROR: ${SERVER_CONTAINER} did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s; rolling back the image"
    if restore_previous_image; then
      compose up -d --force-recreate server worker || log "ERROR: could not restart with the previous image"
    fi
    warn_database_state
    exit 1
  fi

  cleanup
  log "deploy ok: ${image_ref} (pre-deploy dump: ${BACKUP_FILE})"
}

# Run as one pipeline so everything lands in the log too. `main` is defined
# fully before it runs, which also keeps bash from reading half-executed
# statements when the script arrives on stdin.
main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
