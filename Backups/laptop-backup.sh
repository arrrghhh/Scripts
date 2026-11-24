#!/usr/bin/env bash
# =============================================================================
# laptop-backup.sh — config/state backup for the ThinkPad workstation.
#
#   Sources: selected root folders under $HOME, with a denylist for caches,
#            app profiles and credentials. Git repo working trees under
#            Documents/Source are skipped automatically (they live on GitHub).
#   Destinations:
#     NAS   rsync over SSH -> Workstation/<hostname>/daily  (7 dailies)
#     Drive rclone crypt  -> daily x7 / weekly x4 / monthly x12
#
# The archive is stored outside $HOME so it cannot back itself up.
# =============================================================================
set -uo pipefail

NODE="$(hostname)"
HOME_DIR="/home/arrrghhh"
WORK_DIR="/tmp/opencode/laptop-backup"
LOG_FILE="${WORK_DIR}/backup_${NODE}.log"

ARCHIVE="${NODE}-config-$(date +%Y-%m-%d).txz"
ARCHIVE_FILE="${WORK_DIR}/${ARCHIVE}"

NAS_HOST="nas"
NAS_DEST="/media/backup/Backups/Workstation/${NODE}/daily"
NAS_RETENTION_DAYS=7

RCLONE_CONF="${HOME_DIR}/.config/rclone/rclone.conf"
GDRIVE_REMOTE="gdrive-laptop-crypt"
RET_DAILY="7d"
RET_WEEKLY="28d"
RET_MONTHLY="365d"

NOTIFY_SCRIPT="${HOME_DIR}/Documents/Source/Scripts/docker/notify.sh"

mkdir -p "$WORK_DIR"
exec 9>"${WORK_DIR}/.lock"
if ! flock -n 9; then
    echo "$(date '+%F %T') - another laptop backup is running" >&2
    exit 1
fi

log() {
    printf '%s - %s\n' "$(date '+%F %T')" "$1" | tee -a "$LOG_FILE"
}

send_alert() {
    local subject="$1" body="$2"
    if [ -f "$NOTIFY_SCRIPT" ]; then
        bash "$NOTIFY_SCRIPT" laptop-backup "$subject" "$body" >>"$LOG_FILE" 2>&1 || true
    fi
}

die() {
    log "FATAL: $1"
    send_alert "LAPTOP BACKUP FAILED: ${NODE}" "$1"
    exit 1
}

log "===== Laptop backup start: ${NODE} ====="

# --- Exclusions --------------------------------------------------------------
# These are relative to -C "$HOME_DIR".
EXCLUDES=(
    --exclude='.config/google-chrome'
    --exclude='.config/google-chrome-headless'
    --exclude='.config/Code'
    --exclude='.config/Signal'
    --exclude='.config/rclone'
    --exclude='.config/opencode/node_modules'
    --exclude='.config/opencode/secrets'
    --exclude='.config/opencode/service.json'
    --exclude='.config/gh'
    --exclude='.config/privateinternetaccess'
    --exclude='.config/teamviewer'
    --exclude='.config/remmina/remmina.pref'
    --exclude='.config/deluge/auth'
    --exclude='*.log'

    --exclude='.local/share/cleanbackup-*'
    --exclude='.local/share/opencode-scratch-*'
    --exclude='.local/share/opencode'
    --exclude='.local/share/opentui'
    --exclude='.local/share/keyrings'
    --exclude='.local/share/pki'
    --exclude='.local/share/Trash'
    --exclude='.local/share/gvfs-metadata'
    --exclude='.local/share/recently-used.xbel'
)

# Skip git working trees under Documents/Source; they are already on GitHub.
if [ -d "${HOME_DIR}/Documents/Source" ]; then
    for repo_dir in "${HOME_DIR}"/Documents/Source/*; do
        [ -d "${repo_dir}/.git" ] || continue
        EXCLUDES+=( --exclude="Documents/Source/$(basename "$repo_dir")" )
    done
fi

# --- Archive -----------------------------------------------------------------
log "Creating ${ARCHIVE}"
tar --warning=no-file-changed --ignore-failed-read \
    "${EXCLUDES[@]}" \
    --use-compress-program='xz -6 -T0' \
    -cf "$ARCHIVE_FILE" -C "$HOME_DIR" \
    .config .local bin Desktop Documents >>"$LOG_FILE" 2>&1
tar_rc=$?
if [ "$tar_rc" -gt 1 ]; then
    die "tar exited with code ${tar_rc}"
fi

# Defense in depth: abort if a credential-like path slipped through.
if tar --use-compress-program=xz -tf "$ARCHIVE_FILE" 2>/dev/null \
    | grep -Eiq '(^|/)(secrets|rclone|keyrings|pki)(/|$)|(^|/)(rclone\.conf|alert\.env|service\.json|remmina\.pref|auth|id_[A-Za-z0-9_]*|.*\.pem)$'; then
    rm -f "$ARCHIVE_FILE"
    die "credential-like path found in archive; upload aborted"
fi

if ! tar --use-compress-program=xz -tf "$ARCHIVE_FILE" >/dev/null 2>&1; then
    die "archive integrity check failed"
fi
log "Archive verified: $(numfmt --to=iec --suffix=B --format='%.1f' "$(stat -c %s "$ARCHIVE_FILE")")"

# --- NAS ---------------------------------------------------------------------
log "Uploading to ${NAS_HOST}:${NAS_DEST}/"
if ! ssh "$NAS_HOST" "mkdir -p '${NAS_DEST}'" >>"$LOG_FILE" 2>&1; then
    die "could not create NAS destination directory"
fi
if ! rsync -ah --info=stats1 "$ARCHIVE_FILE" "${NAS_HOST}:${NAS_DEST}/" >>"$LOG_FILE" 2>&1; then
    die "rsync to NAS failed"
fi
if ! ssh "$NAS_HOST" "find '${NAS_DEST}' -maxdepth 1 -type f -name '${NODE}-config-*.txz' -mtime +${NAS_RETENTION_DAYS} -delete" >>"$LOG_FILE" 2>&1; then
    log "WARNING: NAS prune failed"
fi
log "NAS upload OK"

# --- Google Drive (encrypted) -------------------------------------------------
for tier in daily weekly monthly; do
    rclone --config "$RCLONE_CONF" mkdir "${GDRIVE_REMOTE}:${tier}" >>"$LOG_FILE" 2>&1 \
        || die "could not create GDrive tier ${tier}"
done

log "Uploading to ${GDRIVE_REMOTE}:daily/"
rclone --config "$RCLONE_CONF" copy "$ARCHIVE_FILE" "${GDRIVE_REMOTE}:daily" \
    --log-level ERROR --tpslimit 5 >>"$LOG_FILE" 2>&1 \
    || die "rclone copy to daily failed"

DOW="$(date +%u)"
DOM="$(date +%d)"
if [ "$DOW" = "7" ]; then
    log "Sunday — promoting to weekly"
    rclone --config "$RCLONE_CONF" copy "$ARCHIVE_FILE" "${GDRIVE_REMOTE}:weekly" \
        --log-level ERROR --tpslimit 5 >>"$LOG_FILE" 2>&1 \
        || die "rclone copy to weekly failed"
fi
if [ "$DOM" = "01" ]; then
    log "1st of month — promoting to monthly"
    rclone --config "$RCLONE_CONF" copy "$ARCHIVE_FILE" "${GDRIVE_REMOTE}:monthly" \
        --log-level ERROR --tpslimit 5 >>"$LOG_FILE" 2>&1 \
        || die "rclone copy to monthly failed"
fi

for tier_age in "daily:${RET_DAILY}" "weekly:${RET_WEEKLY}" "monthly:${RET_MONTHLY}"; do
    tier="${tier_age%%:*}"
    age="${tier_age##*:}"
    rclone --config "$RCLONE_CONF" delete "${GDRIVE_REMOTE}:${tier}" \
        --max-depth 1 --include "${NODE}-config-*.txz" --min-age "$age" --tpslimit 5 \
        >>"$LOG_FILE" 2>&1 || log "WARNING: GDrive prune failed for ${tier}"
done
log "GDrive upload OK"

# --- Cleanup ------------------------------------------------------------------
find "$WORK_DIR" -maxdepth 1 -type f -name "${NODE}-config-*.txz" -mtime +1 -delete
log "===== Laptop backup complete: ${NODE} ====="
exit 0
