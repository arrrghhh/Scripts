#!/bin/bash
# conf-sync.sh <endpoint> — fetch, validate, then fast-forward the shared checkout.
#
# A broken commit can never take an endpoint down: the candidate compose file is
# syntax/interpolation-checked with the live .env before the checkout moves, and
# the scripts the units execute are syntax-checked too.
# No Google Drive / FUSE involvement anywhere.

set -euo pipefail

ENDPOINT="${1:?usage: conf-sync.sh <endpoint>}"
REPO="/home/arrrghhh/Scripts"
DIR="$REPO/docker/$ENDPOINT"
LOCK="$REPO/.git/docker-conf-sync.lock"
BASE="$REPO/docker"

export GIT_TERMINAL_PROMPT=0

log() { echo "[$(date -u +%FT%TZ)] $*"; }

notify_fail() {
  local subject="$1"
  local body="$2"
  /bin/bash "$BASE/notify.sh" "$ENDPOINT" "$subject" "$body" || true
}

on_error() {
  local rc=$?
  local line=$1
  notify_fail "conf-sync failed (exit $rc)" "conf-sync.sh failed on line $line for $ENDPOINT.
See journalctl -u docker-conf-sync@$ENDPOINT.service for details."
  exit $rc
}
trap 'on_error $LINENO' ERR

exec 9>"$LOCK"
flock -n 9 || { log "another sync is already running"; exit 0; }

git -C "$REPO" fetch --quiet origin main

if [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ]; then
  log "already at $(git -C "$REPO" rev-parse --short HEAD)"
  exit 0
fi

if [ ! -f "$DIR/.env" ]; then
  log "ERROR: $DIR/.env is missing; refusing to sync"
  notify_fail "conf-sync failed" "$DIR/.env is missing; sync refused for $ENDPOINT."
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$REPO" show "origin/main:docker/$ENDPOINT/docker-compose.yml" > "$tmp/docker-compose.yml"
git -C "$REPO" show "origin/main:docker/dockerupdate.sh"            > "$tmp/dockerupdate.sh"
git -C "$REPO" show "origin/main:Backups/backup.sh"                 > "$tmp/backup.sh"

if ! docker compose -f "$tmp/docker-compose.yml" --env-file "$DIR/.env" config -q; then
  log "ERROR: candidate compose for $ENDPOINT is invalid; keeping current files"
  notify_fail "conf-sync rejected invalid compose" "Candidate docker/$ENDPOINT/docker-compose.yml failed validation (docker compose config -q). Current files unchanged."
  exit 1
fi

if ! bash -n "$tmp/dockerupdate.sh"; then
  log "ERROR: candidate dockerupdate.sh has a syntax error; keeping current files"
  notify_fail "conf-sync rejected invalid dockerupdate.sh" "Candidate docker/dockerupdate.sh failed bash -n. Current files unchanged."
  exit 1
fi

if ! bash -n "$tmp/backup.sh"; then
  log "ERROR: candidate Backups/backup.sh has a syntax error; keeping current files"
  notify_fail "conf-sync rejected invalid Backups/backup.sh" "Candidate Backups/backup.sh failed bash -n. Current files unchanged."
  exit 1
fi

if ! git -C "$REPO" merge-base --is-ancestor HEAD origin/main; then
  log "ERROR: checkout has diverged from origin/main; manual fix required"
  notify_fail "conf-sync refused (diverged)" "Checkout at $REPO has diverged from origin/main for $ENDPOINT; manual fix required."
  exit 1
fi

git -C "$REPO" merge --ff-only --quiet origin/main
log "synced $ENDPOINT to $(git -C "$REPO" rev-parse --short HEAD)"
