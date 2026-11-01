#!/bin/bash
# dockerupdate.sh <endpoint> — nightly docker container update with pull retry.
# Retries transient registry/rate-limit errors (e.g. lscr.io toomanyrequests)
# that previously aborted the whole run and left containers stuck on old images.
#
# Invoked by docker-update@.service with the endpoint name, e.g.:
#   /bin/bash /home/arrrghhh/Scripts/docker/dockerupdate.sh usrv
#
# Output goes to the journal and to a per-run log file, see LOG_DIR below.

set -uo pipefail

ENDPOINT="${1:?usage: dockerupdate.sh <endpoint>}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$BASE/$ENDPOINT/docker-compose.yml"

# Per-run log, named by UTC start time. docker-update@.service sets
# LogsDirectory=docker-update, so systemd creates /var/log/docker-update owned by
# the service user. Without that (e.g. run by hand) fall back to journal only.
LOG_DIR="/var/log/docker-update"
LOG_RETENTION_DAYS=90
LOG_FILE="${LOG_DIR}/$(date -u +%Y-%m-%dT%H%M%SZ).log"
if mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ]; then
  find "$LOG_DIR" -maxdepth 1 -type f -name '[0-9]*.log' \
    -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
  ln -sfn "$(basename "$LOG_FILE")" "${LOG_DIR}/latest.log"
else
  echo "dockerupdate.sh: cannot write $LOG_DIR; logging to journal only" >&2
fi

notify_fail() {
  local subject="$1"
  local body="$2"
  /bin/bash "$BASE/notify.sh" "$ENDPOINT" "$subject" "$body" || true
}

on_error() {
  local rc=$?
  local line=$1
  notify_fail "docker-update failed (exit $rc)" "dockerupdate.sh failed on line $line for $ENDPOINT

Log: $LOG_FILE"
  exit $rc
}
trap 'on_error $LINENO' ERR

if [ ! -f "$COMPOSE" ]; then
  echo "dockerupdate.sh: no compose file for endpoint '$ENDPOINT' ($COMPOSE)" >&2
  notify_fail "docker-update failed" "dockerupdate.sh could not find compose file for $ENDPOINT: $COMPOSE"
  exit 1
fi

ATTEMPTS=4
BASE_SLEEP=30

pull_ok=0
for i in $(seq 1 "$ATTEMPTS"); do
  echo "[$(date -u +%FT%TZ)] pull attempt $i/$ATTEMPTS"
  if docker compose -f "$COMPOSE" pull --quiet 2>&1 | tail -5; then
    pull_ok=1
    break
  fi
  if [ $i -lt "$ATTEMPTS" ]; then
    SLEEP=$((BASE_SLEEP * (2 ** (i - 1))))
    echo "[$(date -u +%FT%TZ)] pull attempt $i failed; sleeping ${SLEEP}s (exponential backoff)"
    sleep "$SLEEP"
  fi
done

echo "[$(date -u +%FT%TZ)] docker compose up"
docker compose -f "$COMPOSE" up -d --remove-orphans

if [ "$pull_ok" -ne 1 ]; then
  echo "[$(date -u +%FT%TZ)] WARNING: image pull failed after $ATTEMPTS attempts; started on existing images"
  notify_fail "docker-update pull failed after $ATTEMPTS attempts" "docker compose pull failed $ATTEMPTS times for $ENDPOINT. Containers were started with existing images.
Log: $LOG_FILE"
  exit 1
fi
echo "[$(date -u +%FT%TZ)] docker update complete"
exit 0
