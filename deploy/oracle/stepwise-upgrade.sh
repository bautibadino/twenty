#!/usr/bin/env bash
# One-time tool for LARGE Twenty version jumps on the Oracle VM. Runs ON the
# server as the deploy user (needs docker). Upgrades the database one minor
# version at a time, each step with that minor's OFFICIAL image, so every
# upgrade command runs with the code it was written for. A direct jump runs
# new code against schema states it never saw upstream (see README, section
# "Saltos grandes de versión"). Then it upgrades with the fork's final image,
# installs the new compose file and starts the final application.
#
# Usage:
#   stepwise-upgrade.sh --from 2.18 --to 2.46 \
#     --final-image twenty-fork:arm64-next \
#     --new-compose /opt/twenty/docker-compose.oracle.yml.new \
#     [--skip-minors 2.33,2.36] [--dry-run]
#
# --skip-minors: minors whose official image does not exist on Docker Hub (the
# dry run reports them; v2.33 and v2.36 were never published). The next image's
# `upgrade` runs the skipped minor's commands too, because the upgrade sequence
# is cumulative. This is the path every Docker user of upstream had to take.
#
# Flow: preconditions (+ DEPLOY_HOLD) -> stop server/worker -> verified dump +
# baseline -> per-minor official-image upgrades -> final image upgrade ->
# install compose, retag, start -> wait for healthy. ANY failure after the dump
# restores it automatically (the application has been stopped since the dump, so
# nothing is lost), restarts the old application and exits non-zero.
#
# Run it inside tmux/screen/nohup: a dropped SSH session sends SIGHUP, which
# triggers the rollback.
#
# Last output line: STEPWISE_OK | STEPWISE_FAILED_ROLLED_BACK |
#                   STEPWISE_FAILED_ROLLBACK_FAILED | STEPWISE_ABORTED_NOTHING_CHANGED
# Exit codes: 0 ok, 1 failed (rolled back or nothing changed), 2 usage,
#             3 rollback failed (manual intervention needed).
#
# Test hook: STEPWISE_TEST_FAIL_AT=<minor> makes the run fail right before that
# minor is processed, to exercise the rollback. Never set it in production.
set -euo pipefail

# ---------------------------------------------------------------------------
# Server-specific names. Every one can be overridden through the environment
# (the rehearsal uses differently named containers, paths and ports).
# ---------------------------------------------------------------------------
STACK_DIR=${STACK_DIR:-/opt/twenty}
COMPOSE_FILE=${COMPOSE_FILE:-$STACK_DIR/docker-compose.oracle.yml}
ENV_FILE=${ENV_FILE:-$STACK_DIR/.env}
DB_CONTAINER=${DB_CONTAINER:-twenty_db_oracle}
REDIS_CONTAINER=${REDIS_CONTAINER:-twenty_redis_oracle}
SERVER_CONTAINER=${SERVER_CONTAINER:-twenty_server_oracle}
WORKER_CONTAINER=${WORKER_CONTAINER:-twenty_worker_oracle}
NETWORK_NAME=${NETWORK_NAME:-twenty-oracle_twenty_internal_oracle}
SERVICE_DB=${SERVICE_DB:-db}
SERVICE_REDIS=${SERVICE_REDIS:-redis}
SERVICE_SERVER=${SERVICE_SERVER:-server}
SERVICE_WORKER=${SERVICE_WORKER:-worker}
LOCAL_IMAGE=${LOCAL_IMAGE:-twenty-fork}
CURRENT_TAG=${CURRENT_TAG:-arm64}
PREVIOUS_TAG=${PREVIOUS_TAG:-arm64-previous}
HOST_HEALTH_URL=${HOST_HEALTH_URL:-http://127.0.0.1:3000/healthz}
OFFICIAL_IMAGE_REPO=${OFFICIAL_IMAGE_REPO:-twentycrm/twenty}

BACKUP_DIR=${BACKUP_DIR:-$STACK_DIR/backups}
LOG_FILE=${LOG_FILE:-$STACK_DIR/stepwise-upgrade.log}
HOLD_FILE=${HOLD_FILE:-$STACK_DIR/DEPLOY_HOLD}
LOCK_DIR=${LOCK_DIR:-$STACK_DIR/.stepwise.lock}
RUN_LOG_ROOT=${RUN_LOG_ROOT:-$STACK_DIR/stepwise-logs}
MIN_FREE_KB=${MIN_FREE_KB:-$((8 * 1024 * 1024))}
HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-300}
PULL_ATTEMPTS=${PULL_ATTEMPTS:-3}
# Workspace commands that upstream added to an already-released minor, so the
# upgrade cursor of an old database never runs them (the workspace twin of the
# skipped instance commands). Run once, with the FIRST image of the range, right
# after its `upgrade`. They are idempotent. 2.9: the workflowRun.stepLogs field
# is missing from workspaces created before it existed, and the 2.46 command
# suspend-paused-agent-steps reads that column ("column run.stepLogs does not
# exist"). Space separated; set it empty to disable.
WORKSPACE_CATCHUP_COMMANDS=${WORKSPACE_CATCHUP_COMMANDS-upgrade:2-9:add-workflow-run-step-logs-field}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
FROM_MINOR=""
TO_MINOR=""
FINAL_IMAGE=""
NEW_COMPOSE=""
SKIP_MINORS=""
DRY_RUN=0

# init -> stopped (app down, no verified dump yet) -> dumped (dump + baseline
# taken) -> finished. Decides what the exit trap has to undo.
STAGE=init
HOLD_CREATED=0
DB_MUTATED=0
COMPOSE_INSTALLED=0
TAGS_CHANGED=0
PG_USER=""
PG_DB=""
STAMP=""
BACKUP_FILE=""
BASELINE_FILE=""
PREV_IMAGE_ID=""
PULLED_IMAGE=""
WORK_DIR=""
OVERRIDE_FILE=""
RUN_LOG_DIR=""
STOP_EPOCH=0
PULL_SECONDS=0
UPGRADE_SECONDS=0
SUMMARY_LINES=()
VERSIONS=()
SKIPPED=()

# A closed terminal (SIGPIPE/EIO on stdout) must not stop the rollback.
trap '' PIPE

log() {
  local line
  line="[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
  printf '%s\n' "$line" >> "$LOG_FILE" 2> /dev/null || true
  printf '%s\n' "$line" 2> /dev/null || true
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat >&2 << 'EOF'
usage: stepwise-upgrade.sh --from <minor> --to <minor> --final-image <image-ref> --new-compose <path> [--skip-minors <m1,m2>] [--dry-run]
  e.g. stepwise-upgrade.sh --from 2.18 --to 2.46 --final-image twenty-fork:arm64-next --new-compose /opt/twenty/docker-compose.oracle.yml.new
EOF
  exit 2
}

# stdin is closed on purpose for every docker child: this script may itself be
# streamed over SSH, and a docker child would swallow the rest of it.
dc() {
  local file=$1
  shift
  docker compose -f "$file" --project-directory "$STACK_DIR" --env-file "$ENV_FILE" "$@" < /dev/null
}

# Same as dc, but every output line goes through log() so it is timestamped and
# lands in the log file. The pipeline keeps dc's exit status (pipefail).
dc_logged() {
  dc "$@" 2>&1 | while IFS= read -r line; do log "    | ${line}"; done
}

psql_q() {
  docker exec "$DB_CONTAINER" psql -U "$PG_USER" -d "${2:-$PG_DB}" -v ON_ERROR_STOP=1 -Atc "$1" < /dev/null
}

strip_ansi() {
  LC_ALL=C sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || usage; FROM_MINOR=$2; shift 2 ;;
      --to) [ "$#" -ge 2 ] || usage; TO_MINOR=$2; shift 2 ;;
      --final-image) [ "$#" -ge 2 ] || usage; FINAL_IMAGE=$2; shift 2 ;;
      --new-compose) [ "$#" -ge 2 ] || usage; NEW_COMPOSE=$2; shift 2 ;;
      --skip-minors) [ "$#" -ge 2 ] || usage; SKIP_MINORS=$2; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h | --help) usage ;;
      *) echo "unknown argument: $1" >&2; usage ;;
    esac
  done
  [ -n "$FROM_MINOR" ] && [ -n "$TO_MINOR" ] && [ -n "$FINAL_IMAGE" ] && [ -n "$NEW_COMPOSE" ] || usage

  local minor_re='^[0-9]+\.[0-9]+$'
  [[ "$FROM_MINOR" =~ $minor_re ]] || { echo "invalid --from (expected e.g. 2.18): $FROM_MINOR" >&2; exit 2; }
  [[ "$TO_MINOR" =~ $minor_re ]] || { echo "invalid --to (expected e.g. 2.46): $TO_MINOR" >&2; exit 2; }
  local image_re='^[a-z0-9][a-z0-9._/:-]*$'
  [[ "$FINAL_IMAGE" =~ $image_re ]] || { echo "invalid --final-image: $FINAL_IMAGE" >&2; exit 2; }
  [ "${FROM_MINOR%%.*}" = "${TO_MINOR%%.*}" ] || { echo "--from and --to must share the major version" >&2; exit 2; }
  [ "${FROM_MINOR##*.}" -le "${TO_MINOR##*.}" ] || { echo "--from must not be greater than --to" >&2; exit 2; }
  [ "$FINAL_IMAGE" != "${LOCAL_IMAGE}:${CURRENT_TAG}" ] \
    || { echo "--final-image must not be ${LOCAL_IMAGE}:${CURRENT_TAG} (that tag is the rollback image)" >&2; exit 2; }

  local major=${FROM_MINOR%%.*} minor version
  for ((minor = ${FROM_MINOR##*.}; minor <= ${TO_MINOR##*.}; minor++)); do
    version="${major}.${minor}"
    if [[ ",${SKIP_MINORS}," == *",${version},"* ]]; then
      [ "$version" != "$FROM_MINOR" ] || { echo "--skip-minors cannot include --from (${FROM_MINOR}): its image applies the skipped instance commands" >&2; exit 2; }
      SKIPPED+=("$version")
    else
      VERSIONS+=("$version")
    fi
  done
  # Every skipped minor must be inside the range.
  local entry
  for entry in $(printf '%s' "$SKIP_MINORS" | tr ',' ' '); do
    [[ "$entry" =~ $minor_re ]] || { echo "invalid --skip-minors entry: ${entry}" >&2; exit 2; }
    [[ " ${VERSIONS[*]} ${SKIPPED[*]+${SKIPPED[*]}} " == *" ${entry} "* ]] || { echo "--skip-minors entry ${entry} is outside ${FROM_MINOR}..${TO_MINOR}" >&2; exit 2; }
  done
}

# ---------------------------------------------------------------------------
# Preconditions: nothing is touched before all of them pass.
# ---------------------------------------------------------------------------
host_platform_arch() {
  case "$(uname -m)" in
    aarch64 | arm64) echo arm64 ;;
    x86_64 | amd64) echo amd64 ;;
    *) uname -m ;;
  esac
}

free_kb() {
  df -Pk "$STACK_DIR" | awk 'NR==2 {print $4}'
}

check_free_disk() {
  local free
  free=$(free_kb)
  if [ "$free" -lt "$MIN_FREE_KB" ]; then
    log "only $((free / 1024)) MB free on ${STACK_DIR}; need at least $((MIN_FREE_KB / 1024)) MB"
    return 1
  fi
}

read_env_value() {
  # No `source` on the .env: it has values with spaces that the shell would run
  # as commands. Same approach as deploy.sh and backup-twenty.sh.
  grep -E "^$1=" "$ENV_FILE" | head -n 1 | cut -d= -f2- || true
}

check_preconditions() {
  log "preconditions"
  docker info > /dev/null 2>&1 < /dev/null \
    || die "docker is not usable by $(id -un) (daemon down, or user not in the docker group)"
  docker compose version > /dev/null 2>&1 < /dev/null || die "docker compose plugin not available"
  [ -d "$STACK_DIR" ] || die "$STACK_DIR not found"
  [ -f "$COMPOSE_FILE" ] || die "$COMPOSE_FILE not found"
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
  [ -f "$NEW_COMPOSE" ] || die "new compose file $NEW_COMPOSE not found"

  PG_USER=$(read_env_value PG_DATABASE_USER)
  PG_DB=$(read_env_value PG_DATABASE_NAME)
  [ -n "$PG_USER" ] && [ -n "$PG_DB" ] || die "PG_DATABASE_USER / PG_DATABASE_NAME missing in $ENV_FILE"

  if [ -e "${COMPOSE_FILE}.pre-stepwise" ] && ! cmp -s "$NEW_COMPOSE" "$COMPOSE_FILE"; then
    die "${COMPOSE_FILE}.pre-stepwise already exists from an earlier run; move it away first so the original compose is not overwritten"
  fi

  check_free_disk || die "not enough free disk"

  [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2> /dev/null < /dev/null)" = "true" ] \
    || die "container ${DB_CONTAINER} is not running; refusing to upgrade without a database to back up"
  local networks
  networks=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$DB_CONTAINER" < /dev/null) \
    || die "cannot inspect ${DB_CONTAINER}"
  [[ " ${networks} " == *" ${NETWORK_NAME} "* ]] \
    || die "container ${DB_CONTAINER} is not attached to network ${NETWORK_NAME} (attached to: ${networks})"
  psql_q "select 1" > /dev/null || die "cannot query the database in ${DB_CONTAINER}"

  PREV_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$SERVER_CONTAINER" 2> /dev/null < /dev/null || true)
  if [ -z "$PREV_IMAGE_ID" ]; then
    PREV_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "${LOCAL_IMAGE}:${CURRENT_TAG}" 2> /dev/null < /dev/null || true)
  fi
  [ -n "$PREV_IMAGE_ID" ] || die "cannot determine the application image that runs today (needed for the rollback)"

  docker image inspect "$FINAL_IMAGE" > /dev/null 2>&1 < /dev/null \
    || die "final image ${FINAL_IMAGE} is not present locally"
  # The final upgrade depends on a fork-only command; find out now, not after an
  # hour of upgrades.
  docker run --rm --entrypoint grep "$FINAL_IMAGE" -rqs 'run-skipped-instance-commands' dist/database/commands < /dev/null \
    || die "final image ${FINAL_IMAGE} does not contain the run-skipped-instance-commands command"

  check_new_compose

  check_official_tags
  log "preconditions ok (free: $(($(free_kb) / 1024)) MB, previous app image: ${PREV_IMAGE_ID})"
}

# Docker Hub counts every manifest GET against the anonymous pull limit
# (100 per window per IP), and `docker manifest inspect` is a GET. HEAD requests
# are free, so the tag check uses HEAD; only the first and last image get a GET
# to confirm that a variant for this host's architecture exists.
check_official_tags() {
  command -v curl > /dev/null || die "curl is required for the registry check"
  log "checking official image tags on the registry (${#VERSIONS[@]} versions, HEAD requests)"
  local token="" code version arch api_host=registry-1.docker.io repo_path=$OFFICIAL_IMAGE_REPO first=${OFFICIAL_IMAGE_REPO%%/*}
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
  local auth=()
  if [[ "$first" == *.* || "$first" == *:* ]]; then
    # A mirror such as mirror.gcr.io/twentycrm/twenty; anonymous access, no token.
    api_host=$first
    repo_path=${OFFICIAL_IMAGE_REPO#*/}
  else
    token=$(curl -fsS --retry 3 --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo_path}:pull" < /dev/null \
      | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p') || true
    [ -n "$token" ] || die "could not get a registry token from auth.docker.io"
    auth=(-H "Authorization: Bearer ${token}")
  fi
  for version in "${VERSIONS[@]}"; do
    code=$(curl -sI --retry 3 --max-time 20 -o /dev/null -w '%{http_code}' ${auth[@]+"${auth[@]}"} -H "Accept: ${accept}" \
      "https://${api_host}/v2/${repo_path}/manifests/v${version}" < /dev/null) || code=000
    case "$code" in
      200) ;;
      404) die "official image ${OFFICIAL_IMAGE_REPO}:v${version} does not exist on the registry (if the minor was never published, pass --skip-minors ${version})" ;;
      *) die "registry check for ${OFFICIAL_IMAGE_REPO}:v${version} answered HTTP ${code} (rate limit or network); nothing was changed" ;;
    esac
  done
  arch=$(host_platform_arch)
  for version in "${VERSIONS[0]}" "${VERSIONS[${#VERSIONS[@]} - 1]}"; do
    docker manifest inspect "${OFFICIAL_IMAGE_REPO}:v${version}" < /dev/null 2> /dev/null | grep -q "\"architecture\": *\"${arch}\"" \
      || die "official image ${OFFICIAL_IMAGE_REPO}:v${version} has no ${arch} variant (or the registry refused the request)"
  done
  [ -z "$token" ] || check_pull_budget
}

# Anonymous pulls are limited per IP. One pull of an image costs 1-2 requests.
check_pull_budget() {
  local needed=$((${#VERSIONS[@]} * 2 + 4)) remaining probe_token
  if grep -q 'index.docker.io\|"credsStore"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2> /dev/null; then
    log "docker credentials are configured; skipping the anonymous pull-limit check"
    return 0
  fi
  probe_token=$(curl -fsS --max-time 20 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull' < /dev/null \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p') || true
  [ -n "$probe_token" ] || { log "WARNING: could not read the Docker Hub pull limit"; return 0; }
  remaining=$(curl -sI --max-time 20 -H "Authorization: Bearer ${probe_token}" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest < /dev/null \
    | tr -d '\r' | sed -n 's/^[Rr]atelimit-remaining: *\([0-9]*\).*/\1/p' | head -n 1) || true
  [ -n "$remaining" ] || { log "WARNING: Docker Hub did not report a pull limit"; return 0; }
  log "anonymous Docker Hub pulls remaining for this IP: ${remaining} (this run needs about ${needed})"
  if [ "$remaining" -lt "$needed" ]; then
    die "not enough anonymous Docker Hub pulls left (${remaining} < ${needed}); run 'docker login' with a free account, or wait for the window to reset"
  fi
}

check_new_compose() {
  local rendered warnings
  warnings=$(mktemp "${TMPDIR:-/tmp}/stepwise-config.XXXXXX")
  if ! rendered=$(dc "$NEW_COMPOSE" config 2> "$warnings"); then
    cat "$warnings" >&2
    rm -f "$warnings"
    die "new compose file does not render (docker compose config failed)"
  fi
  if grep -q 'variable is not set' "$warnings"; then
    log "WARNING: the new compose interpolates variables that are not set in ${ENV_FILE}:"
    grep -o 'The "[A-Za-z0-9_]*" variable' "$warnings" | sort -u | while IFS= read -r line; do log "  $line"; done
  fi
  rm -f "$warnings"
  local container
  for container in "$DB_CONTAINER" "$REDIS_CONTAINER" "$SERVER_CONTAINER" "$WORKER_CONTAINER"; do
    grep -q "container_name: ${container}\$" <<< "$rendered" \
      || die "new compose does not define container_name: ${container}; wrong file?"
  done
  if grep -q 'env_file' <<< "$rendered"; then
    log "WARNING: the new compose still uses env_file; the versioned compose should not"
  fi
}

print_plan() {
  log "PLAN"
  log "  database jump:   ${FROM_MINOR} -> ${TO_MINOR} (${#VERSIONS[@]} official images, one at a time)"
  log "  every version:   cache:flush, run-instance-commands --force --include-slow, upgrade, cache:flush"
  log "                   (run-instance-commands is left out right after a skipped minor)"
  [ -z "$WORKSPACE_CATCHUP_COMMANDS" ] || log "  catch-up:        after ${FROM_MINOR}'s upgrade: ${WORKSPACE_CATCHUP_COMMANDS}"
  log "  final image:     ${FINAL_IMAGE}: cache:flush, run-skipped-instance-commands, upgrade, cache:flush"
  log "  then:            install ${NEW_COMPOSE} as ${COMPOSE_FILE} (old one kept as .pre-stepwise)"
  log "                   tag ${LOCAL_IMAGE}:${CURRENT_TAG} (previous kept as ${LOCAL_IMAGE}:${PREVIOUS_TAG}), start, wait for ${HOST_HEALTH_URL}"
  log "  safety:          DEPLOY_HOLD at ${HOLD_FILE}; verified dump in ${BACKUP_DIR}; automatic rollback on any failure"
  log "  versions:        ${VERSIONS[*]}"
  [ "${#SKIPPED[@]}" -eq 0 ] || log "  skipped minors:  ${SKIPPED[*]} (no official image; the next image's upgrade covers their commands)"
}

# ---------------------------------------------------------------------------
# Application stop / dump / baseline
# ---------------------------------------------------------------------------
stop_application() {
  # The old code must not write while the dump is taken or while the schema is
  # being upgraded: writes after the dump would be lost on a restore.
  log "stopping server and worker"
  STOP_EPOCH=$(date +%s)
  STAGE=stopped
  dc_logged "$COMPOSE_FILE" stop "$SERVICE_SERVER" "$SERVICE_WORKER"
}

take_dump() {
  STAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/prestepwise-${STAMP}.dump"
  BASELINE_FILE="$BACKUP_DIR/prestepwise-${STAMP}.baseline.txt"
  log "pre-stepwise database backup -> ${BACKUP_FILE}"

  if ! docker exec "$DB_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc < /dev/null > "$BACKUP_FILE"; then
    rm -f "$BACKUP_FILE"
    die "pg_dump failed"
  fi
  if [ ! -s "$BACKUP_FILE" ]; then
    rm -f "$BACKUP_FILE"
    die "pg_dump produced an empty file"
  fi
  # A corrupt dump looks identical to a good one until the day it is needed.
  docker exec -i "$DB_CONTAINER" pg_restore --list < "$BACKUP_FILE" > /dev/null \
    || die "dump failed pg_restore --list verification: $BACKUP_FILE"
  log "backup verified: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

  db_snapshot > "$BASELINE_FILE" || die "could not record the baseline"
  STAGE=dumped
  log "baseline recorded (${BASELINE_FILE}):"
  while IFS= read -r line; do log "  baseline $line"; done < "$BASELINE_FILE"
}

# Counts only, never row contents. Identical output before and after a restore
# proves the database is back to the baseline.
db_snapshot() {
  psql_q 'select '"'"'migration|'"'"'||status||'"'"'|'"'"'||count(*) from core."upgradeMigration" group by status' | sort || return 1
  psql_q 'select '"'"'workspace|'"'"'||subdomain||'"'"'|metadataVersion='"'"'||"metadataVersion"||'"'"'|'"'"'||"activationStatus" from core.workspace' | sort || return 1
  psql_q 'select '"'"'metadata|'"'"'||w.subdomain
    ||'"'"'|objects='"'"'||(select count(*) from core."objectMetadata" x where x."workspaceId"=w.id)
    ||'"'"'|fields='"'"'||(select count(*) from core."fieldMetadata" x where x."workspaceId"=w.id)
    ||'"'"'|views='"'"'||(select count(*) from core.view x where x."workspaceId"=w.id)
    ||'"'"'|viewFields='"'"'||(select count(*) from core."viewField" x where x."workspaceId"=w.id)
    from core.workspace w' | sort || return 1
  psql_q 'select '"'"'totals|users='"'"'||(select count(*) from core."user")||'"'"'|userWorkspaces='"'"'||(select count(*) from core."userWorkspace")' || return 1
}

migration_counts() {
  local counts
  counts=$(psql_q 'select status||'"'"'='"'"'||count(*) from core."upgradeMigration" group by status order by status' | paste -sd' ' -)
  printf '%s' "${counts:-none}"
}

count_status() {
  psql_q "select count(*) from core.\"upgradeMigration\" where status='$1'"
}

# ---------------------------------------------------------------------------
# One command with a given official/final image against the live database
# ---------------------------------------------------------------------------
# run_server_command <compose> <image> <output-file> <command> [args...]
# Same environment as the server service (taken from the compose file), only
# the image is swapped through a temporary override file.
run_server_command() {
  local compose=$1 image=$2 out=$3
  shift 3
  printf 'services:\n  %s:\n    image: %s\n' "$SERVICE_SERVER" "$image" > "$OVERRIDE_FILE"

  local status=0
  docker compose -f "$compose" -f "$OVERRIDE_FILE" --project-directory "$STACK_DIR" --env-file "$ENV_FILE" \
    run --rm --no-deps -T \
    -e DISABLE_DB_MIGRATIONS=true -e DISABLE_CRON_JOBS_REGISTRATION=true \
    "$SERVICE_SERVER" node dist/command/command "$@" < /dev/null > "$out" 2>&1 || status=$?

  # `node dist/command/command` is what `yarn command:prod` expands to in every
  # version checked (2.18 .. 2.46). If an image ever lacks it, fall back.
  if [ "$status" -ne 0 ] && grep -qE "Cannot find module .*dist/command/command" "$out"; then
    log "  node dist/command/command not found in ${image}; retrying with yarn command:prod"
    status=0
    docker compose -f "$compose" -f "$OVERRIDE_FILE" --project-directory "$STACK_DIR" --env-file "$ENV_FILE" \
      run --rm --no-deps -T \
      -e DISABLE_DB_MIGRATIONS=true -e DISABLE_CRON_JOBS_REGISTRATION=true \
      "$SERVICE_SERVER" yarn command:prod "$@" < /dev/null > "$out" 2>&1 || status=$?
  fi
  return "$status"
}

show_notable_lines() {
  # Warnings and errors only; the complete output stays in the per-command file.
  strip_ansi < "$1" | grep -E ' (WARN|ERROR) |Upgrade failed|Instance commands failed|failed' \
    | cut -c1-300 | head -n 40 | while IFS= read -r line; do log "    | $line"; done || true
}

# step_command <label> <fatal|soft> <compose> <image> <command> [args...]
step_command() {
  local label=$1 mode=$2 compose=$3 image=$4
  shift 4
  local out="$RUN_LOG_DIR/${label}.log" status=0 started=$SECONDS
  log "  run: $* (${label})"
  run_server_command "$compose" "$image" "$out" "$@" || status=$?
  local elapsed=$((SECONDS - started))
  UPGRADE_SECONDS=$((UPGRADE_SECONDS + elapsed))
  show_notable_lines "$out"

  if [ "$status" -eq 0 ] && grep -qE 'Upgrade failed:|Instance commands failed:' "$out"; then
    log "  ${label}: exit 0 but the output reports a failure"
    status=1
  fi
  if [ "$status" -ne 0 ]; then
    if [ "$mode" = soft ]; then
      log "  warning: ${label} failed (exit ${status}, ${elapsed}s), continuing: full output ${out}"
      return 0
    fi
    log "  ${label} FAILED (exit ${status}, ${elapsed}s): full output ${out}"
    log "  last output lines:"
    strip_ansi < "$out" | tail -n 15 | cut -c1-300 | while IFS= read -r line; do log "    | $line"; done || true
    return 1
  fi
  log "  ${label}: ok (${elapsed}s)"
}

assert_no_failed_migrations() {
  local failed
  failed=$(count_status failed)
  if [ "$failed" != "0" ]; then
    log "core.\"upgradeMigration\" has ${failed} failed row(s): $(psql_q 'select name||'"'"' ('"'"'||status||'"'"')'"'"' from core."upgradeMigration" where status = '"'"'failed'"'"' order by 1 limit 10' | paste -sd, -)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Per-minor official-image upgrades
# ---------------------------------------------------------------------------
pull_image() {
  local image=$1 attempt=1 started=$SECONDS
  while true; do
    if docker pull "$image" < /dev/null > "$RUN_LOG_DIR/pull.log" 2>&1; then
      PULL_SECONDS=$((PULL_SECONDS + SECONDS - started))
      return 0
    fi
    log "  pull attempt ${attempt}/${PULL_ATTEMPTS} of ${image} failed: $(tail -n 1 "$RUN_LOG_DIR/pull.log" | cut -c1-200)"
    [ "$attempt" -lt "$PULL_ATTEMPTS" ] || return 1
    attempt=$((attempt + 1))
    sleep 10
  done
}

upgrade_with_official_image() {
  local version=$1 catch_up=$2
  local image="${OFFICIAL_IMAGE_REPO}:v${version}"
  local started=$SECONDS before after pull_started pulled_here=1

  if [ "${STEPWISE_TEST_FAIL_AT:-}" = "$version" ]; then
    log "TEST HOOK: STEPWISE_TEST_FAIL_AT=${version}, failing on purpose"
    return 1
  fi

  log "=== ${version} (${image})"
  check_free_disk || return 1
  before=$(migration_counts)

  if docker image inspect "$image" > /dev/null 2>&1 < /dev/null; then
    pulled_here=0
  fi
  PULLED_IMAGE=""
  [ "$pulled_here" -eq 0 ] || PULLED_IMAGE=$image
  pull_started=$SECONDS
  pull_image "$image" || { log "pull of ${image} failed"; return 1; }
  local pull_elapsed=$((SECONDS - pull_started))
  log "  pulled ${image} in ${pull_elapsed}s (free: $(($(free_kb) / 1024)) MB)"

  DB_MUTATED=1
  local run_started=$SECONDS
  step_command "${version}-cache-flush-1" soft "$COMPOSE_FILE" "$image" cache:flush
  # Applies the instance commands of this image's sequence that `upgrade` would
  # skip because its cursor is already past them. Upstream adds instance commands
  # to minors that were already released (2.18.0 and 2.21.0 both got one after
  # release), so this is needed at every step, not only the first: without it
  # the 2.23 workspace commands run on a database that lacks the 2.21 column
  # core.applicationRegistration.logoFileId. It only reaches up to this image's
  # own version and re-running an applied command is a no-op.
  # NOT right after a skipped minor: the database then still has to run the
  # skipped minor's workspace commands, and run-instance-commands would apply
  # the instance commands of two minors first, so `upgrade` would resume past
  # those workspace commands (seen with 2.34 after 2.33: "Workspace ... is
  # missing the shared linked timeline activity type"). `upgrade` alone keeps
  # the upstream order there.
  if [ "$catch_up" -eq 1 ]; then
    step_command "${version}-run-instance-commands" fatal "$COMPOSE_FILE" "$image" run-instance-commands --force --include-slow
    assert_no_failed_migrations || return 1
  else
    log "  run-instance-commands skipped: the previous minor was skipped, so ${version}'s upgrade must run its commands in upstream order"
  fi
  step_command "${version}-upgrade" fatal "$COMPOSE_FILE" "$image" upgrade
  assert_no_failed_migrations || return 1
  if [ "$version" = "$FROM_MINOR" ]; then
    local catchup_command
    for catchup_command in $WORKSPACE_CATCHUP_COMMANDS; do
      step_command "${version}-catchup-${catchup_command//[^A-Za-z0-9]/-}" fatal "$COMPOSE_FILE" "$image" "$catchup_command"
    done
  fi
  step_command "${version}-cache-flush-2" soft "$COMPOSE_FILE" "$image" cache:flush
  local run_elapsed=$((SECONDS - run_started))

  after=$(migration_counts)
  log "  ${version} done: upgrade ${run_elapsed}s, pull ${pull_elapsed}s; upgradeMigration ${before} -> ${after}"
  SUMMARY_LINES+=("${version} pull=${pull_elapsed}s upgrade=${run_elapsed}s migrations: ${after}")

  if [ "$pulled_here" -eq 1 ]; then
    # Keeps the disk flat; never touches an image that was there before.
    docker rmi "$image" < /dev/null > /dev/null 2>&1 || log "  warning: could not remove ${image}"
  fi
  PULLED_IMAGE=""
  log "  step ${version} total $((SECONDS - started))s (free: $(($(free_kb) / 1024)) MB)"
}

upgrade_with_final_image() {
  local label_prefix="final"
  local before after started=$SECONDS
  log "=== final image ${FINAL_IMAGE}"
  before=$(migration_counts)
  step_command "${label_prefix}-cache-flush-1" soft "$NEW_COMPOSE" "$FINAL_IMAGE" cache:flush
  step_command "${label_prefix}-run-skipped-instance-commands" fatal "$NEW_COMPOSE" "$FINAL_IMAGE" run-skipped-instance-commands
  assert_no_failed_migrations || return 1
  step_command "${label_prefix}-upgrade" fatal "$NEW_COMPOSE" "$FINAL_IMAGE" upgrade
  assert_no_failed_migrations || return 1
  step_command "${label_prefix}-cache-flush-2" soft "$NEW_COMPOSE" "$FINAL_IMAGE" cache:flush
  after=$(migration_counts)
  log "  final image done in $((SECONDS - started))s; upgradeMigration ${before} -> ${after}"
  SUMMARY_LINES+=("final pull=0s upgrade=$((SECONDS - started))s migrations: ${after}")
}

# ---------------------------------------------------------------------------
# Cutover
# ---------------------------------------------------------------------------
install_new_compose() {
  if cmp -s "$NEW_COMPOSE" "$COMPOSE_FILE"; then
    log "new compose is already installed as ${COMPOSE_FILE}"
    return 0
  fi
  log "installing ${NEW_COMPOSE} as ${COMPOSE_FILE} (old one kept as ${COMPOSE_FILE}.pre-stepwise)"
  cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.pre-stepwise"
  COMPOSE_INSTALLED=1
  cp "$NEW_COMPOSE" "${COMPOSE_FILE}.tmp.$$"
  mv "${COMPOSE_FILE}.tmp.$$" "$COMPOSE_FILE"
}

retag_images() {
  log "tagging: previous app image ${PREV_IMAGE_ID} -> ${LOCAL_IMAGE}:${PREVIOUS_TAG}; ${FINAL_IMAGE} -> ${LOCAL_IMAGE}:${CURRENT_TAG}"
  docker tag "$PREV_IMAGE_ID" "${LOCAL_IMAGE}:${PREVIOUS_TAG}" < /dev/null
  TAGS_CHANGED=1
  docker tag "$FINAL_IMAGE" "${LOCAL_IMAGE}:${CURRENT_TAG}" < /dev/null
}

wait_until_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS)) status=""
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
  log "last observed health status of ${SERVER_CONTAINER}: ${status}"
  return 1
}

wait_worker_running() {
  # The worker has no healthcheck: require it to stay up and not restart-loop.
  sleep 20
  local running restarting
  running=$(docker inspect -f '{{.State.Running}}' "$WORKER_CONTAINER" 2> /dev/null < /dev/null || echo false)
  restarting=$(docker inspect -f '{{.State.Restarting}}' "$WORKER_CONTAINER" 2> /dev/null < /dev/null || echo true)
  if [ "$running" != "true" ] || [ "$restarting" = "true" ]; then
    log "worker ${WORKER_CONTAINER} is not running steadily (running=${running} restarting=${restarting})"
    return 1
  fi
  log "worker ${WORKER_CONTAINER} running"
}

cutover() {
  install_new_compose
  retag_images
  log "starting the stack with the new compose"
  # db/redis may be recreated by the compose change; the data lives in the volume.
  dc_logged "$COMPOSE_FILE" up -d --wait "$SERVICE_DB" "$SERVICE_REDIS"
  dc_logged "$COMPOSE_FILE" up -d "$SERVICE_SERVER" "$SERVICE_WORKER"
  wait_until_healthy || return 1
  wait_worker_running || return 1
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
restore_database() {
  log "restoring the database from ${BACKUP_FILE}"
  psql_q "select pg_terminate_backend(pid) from pg_stat_activity where datname='${PG_DB}' and pid <> pg_backend_pid()" postgres > /dev/null || return 1
  psql_q "drop database if exists \"${PG_DB}\" with (force)" postgres > /dev/null || return 1
  # -C recreates the database from the dump itself (owner, encoding, settings).
  docker exec -i "$DB_CONTAINER" pg_restore -U "$PG_USER" -d postgres -C --exit-on-error < "$BACKUP_FILE" || return 1

  local after
  after=$(mktemp "${TMPDIR:-/tmp}/stepwise-after.XXXXXX")
  db_snapshot > "$after" || { rm -f "$after"; return 1; }
  if ! diff "$BASELINE_FILE" "$after" > /dev/null; then
    log "restored database does NOT match the baseline; differences (baseline < > restored):"
    diff "$BASELINE_FILE" "$after" | while IFS= read -r line; do log "  $line"; done || true
    rm -f "$after"
    return 1
  fi
  rm -f "$after"
  log "restore verified: snapshot identical to the baseline ($(migration_counts))"
}

# Returns 0 when the old application is back up and healthy.
rollback() {
  log "ROLLBACK start (stage=${STAGE}, database mutated=${DB_MUTATED})"
  local problems=()

  docker stop "$SERVER_CONTAINER" "$WORKER_CONTAINER" < /dev/null > /dev/null 2>&1 || true
  [ -z "$PULLED_IMAGE" ] || docker rmi "$PULLED_IMAGE" < /dev/null > /dev/null 2>&1 || true

  if [ "$COMPOSE_INSTALLED" -eq 1 ] && [ -f "${COMPOSE_FILE}.pre-stepwise" ]; then
    mv "${COMPOSE_FILE}.pre-stepwise" "$COMPOSE_FILE" && log "old compose file restored" \
      || problems+=("could not restore ${COMPOSE_FILE}.pre-stepwise over ${COMPOSE_FILE}")
  fi
  if [ "$TAGS_CHANGED" -eq 1 ]; then
    docker tag "$PREV_IMAGE_ID" "${LOCAL_IMAGE}:${CURRENT_TAG}" < /dev/null \
      && log "tag ${LOCAL_IMAGE}:${CURRENT_TAG} restored to ${PREV_IMAGE_ID}" \
      || problems+=("could not retag ${LOCAL_IMAGE}:${CURRENT_TAG} to ${PREV_IMAGE_ID}")
  fi

  if [ "${#problems[@]}" -eq 0 ]; then
    dc_logged "$COMPOSE_FILE" up -d --wait "$SERVICE_DB" "$SERVICE_REDIS" \
      || problems+=("database/redis containers did not come up with the old compose")
  fi

  if [ "${#problems[@]}" -eq 0 ] && [ "$STAGE" = dumped ] && [ "$DB_MUTATED" -eq 1 ]; then
    restore_database || problems+=("database restore from ${BACKUP_FILE} failed or did not match the baseline")
  elif [ "$STAGE" = dumped ]; then
    log "database was never modified: no restore needed"
  fi

  if [ "${#problems[@]}" -eq 0 ]; then
    # The cache may hold flat entities written by newer code.
    if ! run_server_command "$COMPOSE_FILE" "${LOCAL_IMAGE}:${CURRENT_TAG}" "${RUN_LOG_DIR:-/dev/null}/rollback-cache-flush.log" cache:flush; then
      log "warning: cache:flush with the old image failed; continuing"
    else
      log "cache flushed with the old image"
    fi
    dc_logged "$COMPOSE_FILE" up -d "$SERVICE_SERVER" "$SERVICE_WORKER" \
      || problems+=("could not start the old server and worker")
  fi
  if [ "${#problems[@]}" -eq 0 ]; then
    wait_until_healthy || problems+=("old server did not become healthy on ${HOST_HEALTH_URL}")
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    local problem
    for problem in "${problems[@]}"; do log "ROLLBACK PROBLEM: ${problem}"; done
    return 1
  fi
  log "ROLLBACK complete: old application healthy on ${HOST_HEALTH_URL}"
}

release_lock() {
  rmdir "$LOCK_DIR" 2> /dev/null || true
}

on_exit() {
  local rc=$?
  trap - EXIT
  # A second Ctrl-C or SIGHUP must not interrupt the rollback.
  trap '' INT TERM HUP
  [ "$DRY_RUN" -eq 0 ] || { rm -rf "$WORK_DIR"; exit "$rc"; }
  [ "$rc" -ne 0 ] || [ "$STAGE" = finished ] || rc=1

  if [ "$STAGE" = finished ] && [ "$rc" -eq 0 ]; then
    rm -rf "$WORK_DIR"
    release_lock
    exit 0
  fi

  local final=""
  case "$STAGE" in
    init)
      [ "$HOLD_CREATED" -eq 0 ] || rm -f "$HOLD_FILE"
      final=STEPWISE_ABORTED_NOTHING_CHANGED
      ;;
    stopped)
      # Stopped but no dump yet: nothing changed, just bring the application back.
      log "failure after stopping the application and before the dump: restarting the old application"
      if rollback; then final=STEPWISE_FAILED_ROLLED_BACK; else final=STEPWISE_FAILED_ROLLBACK_FAILED; fi
      ;;
    *)
      if rollback; then final=STEPWISE_FAILED_ROLLED_BACK; else final=STEPWISE_FAILED_ROLLBACK_FAILED; fi
      ;;
  esac

  [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
  if [ "$final" = STEPWISE_FAILED_ROLLBACK_FAILED ]; then
    rc=3
    log "STATE: the application may be DOWN and the database may be partially upgraded."
    log "STATE: verified dump (restore it by hand): ${BACKUP_FILE:-none taken}"
    log "STATE: compose installed=${COMPOSE_INSTALLED} (old copy: ${COMPOSE_FILE}.pre-stepwise), tags changed=${TAGS_CHANGED}, previous image ${PREV_IMAGE_ID}"
    log "STATE: DEPLOY_HOLD left in place; see ${LOG_FILE} and ${RUN_LOG_DIR:-n/a}"
  elif [ "$HOLD_CREATED" -eq 1 ] && [ -f "$HOLD_FILE" ]; then
    printf 'FAILED %s: %s (see %s)\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$final" "$LOG_FILE" >> "$HOLD_FILE" || true
  fi
  [ "$rc" -ne 0 ] || rc=1
  release_lock
  log "$final"
  exit "$rc"
}

# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  mkdir -p "$(dirname "$LOG_FILE")"

  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/stepwise.XXXXXX")
  OVERRIDE_FILE="$WORK_DIR/override.yml"

  if [ "$DRY_RUN" -eq 1 ]; then
    trap on_exit EXIT
    log "stepwise-upgrade DRY RUN (nothing will be changed)"
    print_plan
    check_preconditions
    log "dry run ok: all preconditions pass"
    exit 0
  fi

  if ! mkdir "$LOCK_DIR" 2> /dev/null; then
    echo "another stepwise-upgrade run holds ${LOCK_DIR} (remove it only if no run is active)" >&2
    exit 2
  fi
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  STAMP=$(date +%Y%m%d-%H%M%S)
  RUN_LOG_DIR="$RUN_LOG_ROOT/${STAMP}"
  mkdir -p "$RUN_LOG_DIR"

  log "stepwise-upgrade start: ${FROM_MINOR} -> ${TO_MINOR}, final image ${FINAL_IMAGE}"
  print_plan
  check_preconditions

  # From here on the normal deploy must not run, until this script succeeds.
  printf 'stepwise-upgrade started %s by %s. Do not run deploy.sh. Log: %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(id -un)" "$LOG_FILE" > "$HOLD_FILE"
  HOLD_CREATED=1
  log "DEPLOY_HOLD created: ${HOLD_FILE}"
  log "per-command output: ${RUN_LOG_DIR}"

  stop_application
  take_dump

  local version previous_minor="" catch_up
  for version in "${VERSIONS[@]}"; do
    catch_up=1
    if [ -n "$previous_minor" ] && [ $((previous_minor + 1)) -ne "${version##*.}" ]; then
      catch_up=0
    fi
    upgrade_with_official_image "$version" "$catch_up"
    previous_minor=${version##*.}
  done

  upgrade_with_final_image
  cutover

  local downtime=$(($(date +%s) - STOP_EPOCH))
  STAGE=finished
  rm -f "$HOLD_FILE"
  log "SUMMARY (per version)"
  local line
  for line in ${SUMMARY_LINES[@]+"${SUMMARY_LINES[@]}"}; do log "  $line"; done
  log "SUMMARY downtime (stop -> healthy): ${downtime}s; pulls ${PULL_SECONDS}s; upgrade commands ${UPGRADE_SECONDS}s"
  log "pre-stepwise dump kept: ${BACKUP_FILE} (delete it by hand once the new version is accepted)"
  log "previous app image kept as ${LOCAL_IMAGE}:${PREVIOUS_TAG}; old compose kept as ${COMPOSE_FILE}.pre-stepwise"
  log "DEPLOY_HOLD removed"
  log "STEPWISE_OK"
}

main "$@"
