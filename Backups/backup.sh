#!/usr/bin/env bash
# =============================================================================
# backup.sh v2 — Multi-tier node backup: local HDD + GDrive GFS rotation.
#
#   Daily x7  |  Weekly x4 (Sunday)  |  Monthly x12 (1st)
#
# Run once per day (systemd timer). Weekly/monthly promotion is decided from
# the current date, so the schedule is simply "daily".
#
# IMPORTANT: the GDrive tiers live in SIBLING folders (…/daily, …/weekly,
# …/monthly), never nested. `rclone delete` recurses by default, so a daily
# prune over a parent folder that contains weekly/monthly subfolders would
# delete those tiers too (the v1 bug). All prunes also use `--max-depth 1`
# so a prune can never reach outside its own folder.
#
# See README.md in this directory for deployment.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit me)
# ---------------------------------------------------------------------------
NODE="$(hostname)"

LOCAL_TEMP="/var/tmp/backups_local"
LOG_DIR="/var/log/backup_logs"
LOCK_FILE="/var/run/backup_${NODE}.lock"
LOG_RUN_USER="arrrghhh"

RCLONE_CONF="/home/${LOG_RUN_USER}/.config/rclone/rclone.conf"
RCLONE_REMOTE="gdrive"

PRIMARY_BASE="/media/backup/Backups/UbuntuServer"
PRIMARY_HDD="${PRIMARY_BASE}/${NODE}"
CROSS_PATH="${PRIMARY_BASE}/cross_backups"

HA_BACKUP_DIR="/home/${LOG_RUN_USER}/.homeassistant/backups"

# GFS tiers — SIBLINGS under one node folder. Do not nest these.
GDRIVE_ROOT="${RCLONE_REMOTE}:Backups/ubuntu_backup/Rolling/${NODE}"
GDRIVE_DAILY="${GDRIVE_ROOT}/daily"
GDRIVE_WEEKLY="${GDRIVE_ROOT}/weekly"
GDRIVE_MONTHLY="${GDRIVE_ROOT}/monthly"
GDRIVE_HA_DAILY="${GDRIVE_ROOT}/HA/daily"
GDRIVE_HA_WEEKLY="${GDRIVE_ROOT}/HA/weekly"
GDRIVE_HA_MONTHLY="${GDRIVE_ROOT}/HA/monthly"

# Retention windows. Ages apply to the *contents* of each tier folder and map
# to Daily x7 / Weekly x4 / Monthly x12. Age-based (not count-based) pruning
# is tolerant of missed runs.
RET_DAILY="7d"
RET_WEEKLY="28d"
RET_MONTHLY="365d"
RET_LOCAL=7     # days, local HDD
RET_CROSS=14    # days, incoming cross-backups

# Failure-alert recipient. Empty = disabled.
ALERT_TO=""

# SSH aliases of the other backup nodes (defined in /root/.ssh/config).
NODES=(summitserver nas usrv)

# Directories to back up. The archive is created with `tar -C /`, so these
# are the top-level path components stored in the archive.
SOURCES=(
    "/home"
    "/etc"
    "/usr/local/bin"
    "/var/spool/cron"
)

# Single source of truth for exclude patterns. Patterns starting with '*'
# are used verbatim by tar; all others get a leading '*/' prefix so they match
# at any depth. rsync always uses the plain pattern as-is.
EXCLUDE_PATTERNS=(
    "backups_local"                         # Stops recursive backup loop
    ".homeassistant"                        # Backed up separately via HA section
    ".medusa/Logs"                          # Medusa log history
    ".medusa/cache*"                        # Medusa cache/WAL files
    ".deluge/config/supervisord.log*"       # Deluge log rotation
    ".deluge/supervisord.log*"              # Deluge log rotation
    ".git"                                  # Large .git objects
    "pihole-FTL.db"                         # Large Pi-hole database
    ".sabnzbd/Downloads"                    # Active download data
    ".sabnzbd/logs"                         # SABnzbd log history
    ".sabnzbd/*/logs"                       # SABnzbd nested logs
    ".nginxproxmgr/logs"                    # Nginx Proxy Manager logs
    ".cache"                                # General app caches
    ".vscode-server"                        # VS Code binaries/extensions
    "Dropbox"                               # Cloud-synced data
    ".plex"                                 # Plex metadata
    ".scrypted"                             # NVR/camera caches
    ".frigate/model_cache"                  # Frigate AI model caches
    "*.db-wal"                              # SQLite WAL files
    "*.db-shm"                              # SQLite shared memory files
    "*.js.map"                              # JS source maps
)

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------
START_TIME="$(date +%s)"
DATE="$(date +%Y-%m-%d)"
DOW="$(date +%u)"     # 1=Mon ... 7=Sun
DOM="$(date +%d)"     # zero-padded day of month
IS_WEEKLY=0
IS_MONTHLY=0
[ "$DOW" = "7" ]  && IS_WEEKLY=1
[ "$DOM" = "01" ] && IS_MONTHLY=1

ARCHIVE="${NODE}-backup-${DATE}.tgz"
ARCHIVE_TGZ="${LOCAL_TEMP}/${ARCHIVE}"
ARCHIVE_SRC="${ARCHIVE_TGZ}"

LOG_FILE="${LOG_DIR}/backup_${NODE}_${DATE}.log"
FAILED=0

mkdir -p "$LOCAL_TEMP" "$LOG_DIR" /tmp/fake

# ---------------------------------------------------------------------------
# Lock (flock auto-releases on process death — no stale-lock problem)
# ---------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: another backup is running (${LOCK_FILE})." | tee -a "$LOG_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

record_failure() { FAILED=1; log_msg "  [FAIL] $1"; }

send_alert() {
    local subject="$1" body="$2"
    [ -n "$ALERT_TO" ] || return 0
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$subject" "$ALERT_TO" 2>/dev/null \
            || log_msg "  [WARN] could not send alert via mail"
    elif command -v sendmail >/dev/null 2>&1; then
        { printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_TO" "$subject" "$body"; } | sendmail -t 2>/dev/null \
            || log_msg "  [WARN] could not send alert via sendmail"
    else
        log_msg "  [WARN] no mail/sendmail available to send alert '$subject'"
    fi
}

die() {
    local msg="$1"
    log_msg "FATAL: $msg"
    send_alert "BACKUP FAILED: ${NODE}" "Backup on ${NODE} failed at $(date '+%Y-%m-%d %H:%M:%S').
$msg

Log: ${LOG_FILE}"
    exit 1
}

cleanup() { rm -f "$ARCHIVE_TGZ"; }
trap cleanup EXIT

rclone_copy() {
    local src="$1" dst="$2"
    shift 2
    if rclone --config "$RCLONE_CONF" copy "$src" "$dst" --log-level ERROR "$@" >>"$LOG_FILE" 2>&1; then
        log_msg "  -> OK: ${dst}"
    else
        record_failure "rclone copy failed: ${dst}"
    fi
}

# Prune a local directory: log then delete files matching pattern older than N days.
prune_local() {
    local dir="$1" pattern="$2" days="$3"
    local found=false f
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        log_msg "  [prune] ${f}"
        found=true
    done < <(find "$dir" -type f -name "$pattern" -mtime +"$days" -delete -print 2>/dev/null)
    $found || log_msg "  (nothing to prune)"
}

# Prune a GDrive tier. `--max-depth 1` confines the delete to the tier's own
# files, and `--include` limits it to our own archive pattern — defense in
# depth against ever touching sibling/nested folders.
prune_rclone() {
    local remote="$1" pattern="$2" age="$3"
    local found=false f listing
    # Skip tiers that don't exist yet (e.g. weekly/monthly outside their
    # promotion day, or an empty HA tier) — rclone delete would error out.
    if ! listing="$(rclone --config "$RCLONE_CONF" lsf "$remote" --files-only --max-depth 1 \
                --include "$pattern" --min-age "$age" 2>/dev/null)"; then
        log_msg "  (tier not found — skipping ${remote})"
        return 0
    fi
    while IFS= read -r f; do
        log_msg "  [prune] ${remote}/${f}"
        found=true
    done <<<"$listing"
    if rclone --config "$RCLONE_CONF" delete "$remote" --max-depth 1 \
            --include "$pattern" --min-age "$age" >>"$LOG_FILE" 2>&1; then
        $found || log_msg "  (nothing to prune)"
    else
        record_failure "prune failed: ${remote}"
    fi
}

# ---------------------------------------------------------------------------
log_msg "========================================================"
log_msg "Backup start: ${NODE} ($(date '+%Y-%m-%d %H:%M:%S'))"
log_msg "Tiers today: daily + weekly(x${IS_WEEKLY}) + monthly(x${IS_MONTHLY})"
log_msg "========================================================"

# --- Source inventory (post-exclusion sizes) -------------------------------
EXCLUDES=()
RSYNC_EXCLUDES=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ "$pattern" == \** ]]; then
        EXCLUDES+=( --exclude="$pattern" )
    else
        EXCLUDES+=( --exclude="*/${pattern}" )
    fi
    RSYNC_EXCLUDES+=( --exclude="$pattern" )
done

TOTAL_SOURCE_SIZE_BYTES=0
BACKUP_DIRS=()
log_msg "Source inventory (post-exclusion):"
for dir in "${SOURCES[@]}"; do
    if [ -d "$dir" ]; then
        size_bytes="$(rsync --dry-run --recursive --stats \
                        "${RSYNC_EXCLUDES[@]}" "${dir%/}/" /tmp/fake/ 2>/dev/null \
                      | awk '/Total file size/ {gsub(/[^0-9]/, "", $0); print $0}')"
        size_bytes="${size_bytes:-0}"
        TOTAL_SOURCE_SIZE_BYTES=$(( TOTAL_SOURCE_SIZE_BYTES + size_bytes ))
        log_msg "  [+] ${dir} ($(numfmt --to=iec --suffix=B --format='%.1f' "$size_bytes"))"
        BACKUP_DIRS+=( "${dir#/}" )
    else
        log_msg "  [!] skipping ${dir} (not found)"
    fi
done

# --- Create archive ---------------------------------------------------------
log_msg "Creating archive: ${ARCHIVE_TGZ}"
tar --warning=no-file-changed --ignore-failed-read \
    "${EXCLUDES[@]}" \
    --checkpoint=5000 \
    --checkpoint-action='echo=  ... compressed %u blocks' \
    -czf "$ARCHIVE_TGZ" -C / "${BACKUP_DIRS[@]}" >>"$LOG_FILE" 2>&1
TAR_EXIT=$?
if [ "$TAR_EXIT" -gt 1 ]; then
    die "tar exited with code ${TAR_EXIT}"
fi

log_msg "Verifying archive integrity..."
if ! tar -tzf "$ARCHIVE_TGZ" >/dev/null 2>&1; then
    die "integrity check failed for ${ARCHIVE}"
fi
log_msg "Integrity check passed."

# --- Distribute -------------------------------------------------------------
if [ -d "$PRIMARY_BASE" ]; then
    log_msg "Moving archive to HDD..."
    mkdir -p "$PRIMARY_HDD"
    if rsync -ah --remove-source-files "$ARCHIVE_TGZ" "${PRIMARY_HDD}/" >>"$LOG_FILE" 2>&1; then
        ARCHIVE_SRC="${PRIMARY_HDD}/${ARCHIVE}"
    else
        record_failure "could not move archive to HDD — continuing from temp"
    fi
else
    log_msg "WARNING: primary HDD not available — uploading straight from temp."
fi

log_msg "Uploading to GDrive daily (${GDRIVE_DAILY})..."
rclone_copy "$ARCHIVE_SRC" "$GDRIVE_DAILY"

if [ "$IS_WEEKLY" = "1" ]; then
    log_msg "Sunday — promoting to GDrive weekly (${GDRIVE_WEEKLY})..."
    rclone_copy "$ARCHIVE_SRC" "$GDRIVE_WEEKLY"
fi

if [ "$IS_MONTHLY" = "1" ]; then
    log_msg "1st of month — promoting to GDrive monthly (${GDRIVE_MONTHLY})..."
    rclone_copy "$ARCHIVE_SRC" "$GDRIVE_MONTHLY"
fi

log_msg "Pruning GDrive tiers..."
prune_rclone "$GDRIVE_DAILY"   "${NODE}-backup-*.tgz" "$RET_DAILY"
prune_rclone "$GDRIVE_WEEKLY"  "${NODE}-backup-*.tgz" "$RET_WEEKLY"
prune_rclone "$GDRIVE_MONTHLY" "${NODE}-backup-*.tgz" "$RET_MONTHLY"

log_msg "Pruning local HDD backups (>${RET_LOCAL}d)..."
prune_local "$PRIMARY_HDD" "${NODE}-backup-*.tgz" "$RET_LOCAL"

# --- Cross-node push ---------------------------------------------------------
for TARGET in "${NODES[@]}"; do
    [ "$TARGET" = "$NODE" ] && continue
    log_msg "Pushing cross-backup to ${TARGET}..."
    if rsync -ahq --mkpath --info=stats1 \
            "$ARCHIVE_SRC" "root@${TARGET}:${CROSS_PATH}/${NODE}/" >>"$LOG_FILE" 2>&1; then
        log_msg "  -> OK"
    else
        log_msg "  [WARN] cross-backup to ${TARGET} failed (non-fatal)."
    fi
done

# --- Incoming cross-backup pruning ------------------------------------------
if [ -d "$CROSS_PATH" ]; then
    log_msg "Pruning incoming cross-backups (>${RET_CROSS}d)..."
    prune_local "$CROSS_PATH" "*.tgz" "$RET_CROSS"
fi

# --- Home Assistant backups ---------------------------------------------------
if [ -d "$HA_BACKUP_DIR" ]; then
    log_msg "Syncing Home Assistant backups to GDrive..."
    rclone_copy "$HA_BACKUP_DIR" "$GDRIVE_HA_DAILY" --max-age 24h

    if [ "$IS_WEEKLY" = "1" ]; then
        log_msg "Sunday — HA backup to weekly (${GDRIVE_HA_WEEKLY})..."
        rclone_copy "$HA_BACKUP_DIR" "$GDRIVE_HA_WEEKLY" --max-age 24h
    fi

    if [ "$IS_MONTHLY" = "1" ]; then
        log_msg "1st of month — HA backup to monthly (${GDRIVE_HA_MONTHLY})..."
        rclone_copy "$HA_BACKUP_DIR" "$GDRIVE_HA_MONTHLY" --max-age 24h
    fi

    log_msg "Pruning GDrive HA tiers..."
    prune_rclone "$GDRIVE_HA_DAILY"   "*.tar" "$RET_DAILY"
    prune_rclone "$GDRIVE_HA_WEEKLY"  "*.tar" "$RET_WEEKLY"
    prune_rclone "$GDRIVE_HA_MONTHLY" "*.tar" "$RET_MONTHLY"
fi

# --- Stats -------------------------------------------------------------------
if [ -f "$ARCHIVE_SRC" ]; then
    final_size_bytes="$(stat -c %s "$ARCHIVE_SRC" 2>/dev/null || echo 0)"
    pretty_source="$(numfmt --to=iec --suffix=B --format='%.1f' "$TOTAL_SOURCE_SIZE_BYTES")"
    pretty_final="$(numfmt --to=iec --suffix=B --format='%.1f' "$final_size_bytes")"
    if [ "$TOTAL_SOURCE_SIZE_BYTES" -gt 0 ] && [ "$final_size_bytes" -gt 0 ]; then
        ratio="$(awk -v a="$final_size_bytes" -v b="$TOTAL_SOURCE_SIZE_BYTES" \
                 'BEGIN { printf "%.1f", (a / b) * 100 }')"
        log_msg "Stats | Source: ${pretty_source} | Archive: ${pretty_final} | Ratio: ${ratio}%"
    else
        log_msg "Stats | Source: ${pretty_source} | Archive: ${pretty_final}"
    fi
fi

# --- Finish -------------------------------------------------------------------
END_TIME="$(date +%s)"
DIFF=$(( END_TIME - START_TIME ))
chown -R "$LOG_RUN_USER" "$LOG_DIR" 2>/dev/null || true

if [ "$FAILED" = "1" ]; then
    send_alert "BACKUP ISSUES: ${NODE}" "Backup on ${NODE} finished with errors at $(date '+%Y-%m-%d %H:%M:%S').
Review the log: ${LOG_FILE}"
    log_msg "Backup finished WITH ERRORS in $((DIFF / 60))m $((DIFF % 60))s."
else
    log_msg "Backup completed successfully in $((DIFF / 60))m $((DIFF % 60))s."
fi

# --- Monthly log archiving (1st of month) -------------------------------------
if [ "$IS_MONTHLY" = "1" ]; then
    LAST_MONTH="$(date -d 'last month' +%Y-%m)"
    ARCHIVE_DIR="${LOG_DIR}/archives"
    mkdir -p "$ARCHIVE_DIR"
    shopt -s nullglob
    log_files=( "$LOG_DIR"/*"${LAST_MONTH}"* )
    shopt -u nullglob
    if [ "${#log_files[@]}" -gt 0 ]; then
        tar -czf "${ARCHIVE_DIR}/backup_logs_${LAST_MONTH}.tgz" \
            -C "$LOG_DIR" "${log_files[@]##*/}" >>"$LOG_FILE" 2>&1
        find "$LOG_DIR" -maxdepth 1 -name "*${LAST_MONTH}*" -delete
        log_msg "Log archive created: backup_logs_${LAST_MONTH}.tgz"
    else
        log_msg "No logs found for ${LAST_MONTH}; skipping log archive."
    fi
    find "$ARCHIVE_DIR" -name '*.tgz' -mtime +365 -delete
fi
