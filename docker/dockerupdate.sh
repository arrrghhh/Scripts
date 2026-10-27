#!/bin/bash
# dockerupdate.sh <endpoint> — nightly docker container update with pull retry.
# Retries transient registry/rate-limit errors (e.g. lscr.io toomanyrequests)
# that previously aborted the whole run and left containers stuck on old images.
#
# Invoked by docker-update@.service with the endpoint name, e.g.:
#   /bin/bash /home/arrrghhh/Scripts/docker/dockerupdate.sh usrv

set -u

ENDPOINT="${1:?usage: dockerupdate.sh <endpoint>}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$BASE/$ENDPOINT/docker-compose.yml"

notify_fail() {
  local subject="$1"
  local body="$2"
  /bin/bash "$BASE/notify.sh" "$ENDPOINT" "$subject" "$body" || true
}

on_error() {
  local rc=$?
  local line=$1
  notify_fail "docker-update failed (exit $rc)" "dockerupdate.sh failed on line $line for $ENDPOINT

Command that failed (last): see journal for details."
  exit $rc
}
trap 'on_error $LINENO' ERR

if [ ! -f "$COMPOSE" ]; then
  echo "dockerupdate.sh: no compose file for endpoint '$ENDPOINT' ($COMPOSE)" >&2
  notify_fail "docker-update failed" "dockerupdate.sh could not find compose file for $ENDPOINT: $COMPOSE"
  exit 1
fi

ATTEMPTS=3
SLEEP=60

pull_ok=0
for i in $(seq 1 "$ATTEMPTS"); do
  echo "[$(date -u +%FT%TZ)] pull attempt $i/$ATTEMPTS"
  if docker compose -f "$COMPOSE" pull --quiet; then
    pull_ok=1
    break
  fi
  echo "[$(date -u +%FT%TZ)] pull attempt $i failed; sleeping ${SLEEP}s"
  sleep "$SLEEP"
done

echo "[$(date -u +%FT%TZ)] docker compose up"
docker compose -f "$COMPOSE" up -d --remove-orphans

if [ "$pull_ok" -ne 1 ]; then
  echo "[$(date -u +%FT%TZ)] WARNING: image pull failed after $ATTEMPTS attempts; started on existing images"
  notify_fail "docker-update pull failed after $ATTEMPTS attempts" "docker compose pull failed $ATTEMPTS times for $ENDPOINT. Containers were started with existing images.
See journalctl -u docker-update@$ENDPOINT.service for details."
  exit 1
fi
echo "[$(date -u +%FT%TZ)] docker update complete"
exit 0
