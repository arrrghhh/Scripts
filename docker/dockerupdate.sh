#!/bin/bash
# dockerupdate.sh <endpoint> — nightly docker container update with pull retry.
# Retries transient registry/rate-limit errors (e.g. lscr.io toomanyrequests)
# that previously aborted the whole run and left containers stuck on old images.
#
# Invoked by docker-update@.service with the endpoint name, e.g.:
#   /bin/bash /home/arrrghhh/docker-compose/docker/dockerupdate.sh usrv

set -u

ENDPOINT="${1:?usage: dockerupdate.sh <endpoint>}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$BASE/$ENDPOINT/docker-compose.yml"

if [ ! -f "$COMPOSE" ]; then
  echo "dockerupdate.sh: no compose file for endpoint '$ENDPOINT' ($COMPOSE)" >&2
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
  exit 1
fi
echo "[$(date -u +%FT%TZ)] docker update complete"
exit 0
