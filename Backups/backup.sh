#!/bin/bash
# =============================================================================
# backup.sh — Multi-tier backup: local HDD + GDrive GFS rotation
#             Daily x7 | Weekly x4 (Sun) | Monthly x12 (1st)
# =============================================================================
set -uo pipefail

# --- 1. Identity & Paths -----------------------------------------------------
START_TIME=$(date +%s)
NODE=$(hostname)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)   # 1=Mon … 7=Sun
DOM=$(date +%d)   # day-of-month

LOCAL_TEMP="/var/tmp/backups_local"
LOG_DIR="/var/log/backup_logs"
LOG_FILE="${LOG_DIR}/backup_${NODE}_${DATE}.log"
LOCK_FILE="/var/run/backup_${NODE}.lock"

RCLONE_CONF="/home/arrrghhh/.config/rclone/rclone.conf"

PRIMARY_BASE="/media/backup/Backups/UbuntuServer"
PRIMARY_HDD="${PRIMARY_BASE}/${NODE}"
CROSS_PATH="${PRIMARY_BASE}/cross_backups"

# GDrive paths
GDRIVE_DAILY="gdrive:Backups/ubuntu_backup/Rolling/${NODE}"
GDRIVE_WEEKLY="gdrive:Backups/ubuntu_backup/Rolling/${NODE}/weekly"
GDRIVE_MONTHLY="gdrive:Backups/ubuntu_backup/Rolling/${NODE}/monthly"

# Use the aliases defined in /root/.ssh/config
NODES=("summitserver" "nas" "usrv")

ARCHIVE="${NODE}-backup-${DATE}.tgz"

mkdir -p "$LOCAL_TEMP" "$LOG_DIR"

# --- 2. Lock file (prevents overlapping cron runs) ---------------------------
if [ -e "$LOCK_FILE" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR: Lock file exists. Another backup may be running. Exiting." \
        | tee -a "$LOG_FILE"
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

# --- 3. Logging helpers ------------------------------------------------------
log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# Trap unexpected errors and report line number
trap 'log_msg "ERROR: Unexpected failure at line ${LINENO}. Exiting."; exit 1' ERR

# Prune a local directory: log then delete files matching pattern older than N days
prune_local() {
    local dir="$1" pattern="$2" days="$3"
    local found=false
    while IFS= read -r f; do
        log_msg "  [pruning] $f"
        found=true
    done < <(find "$dir" -name "$pattern" -mtime +"$days")
    find "$dir" -name "$pattern" -mtime +"$days" -delete
    $found || log_msg "  (nothing to prune)"
}

# Prune a GDrive remote: log then delete files older than age string
prune_rclone() {
    local remote="$1" age="$2"
    local found=false
    while IFS= read -r f; do
        log_msg "  [pruning] ${remote}/${f}"
        found=true
    done < <(rclone --config "$RCLONE_CONF" lsf "$remote" --min-age "$age" 2>/dev/null)
    rclone --config "$RCLONE_CONF" delete "$remote" --min-age "$age" >> "$LOG_FILE" 2>&1
    $found || log_msg "  (nothing to prune)"
}

log_msg "========================================================"
log_msg "Starting backup for node: $NODE"
log_msg "========================================================"

# --- 4. Sources & Exclusions -------------------------------------------------
SOURCES=(
    "/home"
    "/etc"
    "/usr/local/bin"
    "/var/spool/cron"
    "/media/complete/sabnzbd"
)

# Single source of truth for exclude patterns.
# Patterns starting with * are used as-is for tar; others get a leading */ prefix.
# rsync always uses the plain pattern as-is.
EXCLUDE_PATTERNS=(
    "backups_local"                         # Stops recursive backup loop
    ".homeassistant"                        # Backed up separately via HA section below
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

# Build tar and rsync exclude flag arrays from the single pattern list
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

# --- 5. Source inventory (post-exclusion size via rsync dry-run) -------------
TOTAL_SOURCE_SIZE_BYTES=0
BACKUP_FILES=()

log_msg "Source inventory (post-exclusion):"
for dir in "${SOURCES[@]}"; do
    if [ -d "$dir" ]; then
        set +e
        size_bytes=$(rsync --dry-run --recursive --stats \
                        "${RSYNC_EXCLUDES[@]}" \
                        "${dir}/" /tmp/fake/ 2>/dev/null \
                    | awk '/Total file size/ {gsub(/,/,"",$4); print $4}')
        set -e
        size_bytes=${size_bytes:-0}
        TOTAL_SOURCE_SIZE_BYTES=$(( TOTAL_SOURCE_SIZE_BYTES + size_bytes ))
        human_size=$(numfmt --to=iec --suffix=B --format="%.1f" "$size_bytes")
        log_msg "  [+] $dir (${human_size})"
        BACKUP_FILES+=( "${dir#/}" )
    else
        log_msg "  [!] Skipping $dir (not found)"
    fi
done

# --- 6. Create archive -------------------------------------------------------
log_msg "Creating archive: ${LOCAL_TEMP}/${ARCHIVE}"

# Capture tar exit code without triggering ERR trap (exit 1 = warnings, which is acceptable)
set +e
tar --warning=no-file-changed \
    --ignore-failed-read \
    "${EXCLUDES[@]}" \
    --checkpoint=5000 \
    --checkpoint-action=echo="  ... compressed %u blocks" \
    -czf "${LOCAL_TEMP}/${ARCHIVE}" \
    -C / "${BACKUP_FILES[@]}" >> "$LOG_FILE" 2>&1
TAR_EXIT=$?
set -e

if [ "$TAR_EXIT" -gt 1 ]; then
    log_msg "ERROR: tar exited with code $TAR_EXIT. Backup aborted."
    exit 1
fi

# Integrity check
log_msg "Verifying archive integrity..."
if ! tar -tzf "${LOCAL_TEMP}/${ARCHIVE}" > /dev/null 2>&1; then
    log_msg "ERROR: Integrity check failed. Backup aborted."
    exit 1
fi
log_msg "Integrity check passed."

# --- 7. Distribute archive ---------------------------------------------------
if [ -d "$PRIMARY_BASE" ]; then
    log_msg "Primary HDD storage available."
    mkdir -p "$PRIMARY_HDD"

    log_msg "Moving archive to HDD..."
    rsync -ah --remove-source-files \
          "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/" 2>&1 \
          | grep -E 'sent|total size' >> "$LOG_FILE" || true

    # --- 8. GDrive GFS rotation ----------------------------------------------
    log_msg "Uploading to GDrive daily (${GDRIVE_DAILY})..."
    rclone --config "$RCLONE_CONF" \
        copy "${PRIMARY_HDD}/${ARCHIVE}" "$GDRIVE_DAILY" \
        --log-level ERROR >> "$LOG_FILE" 2>&1

    # Weekly and monthly promote directly from local HDD — avoids a GDrive round-trip
    if [ "$DOW" = "7" ]; then
        log_msg "Sunday — copying to GDrive weekly (${GDRIVE_WEEKLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "${PRIMARY_HDD}/${ARCHIVE}" "$GDRIVE_WEEKLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    if [ "$DOM" = "01" ]; then
        log_msg "1st of month — copying to GDrive monthly (${GDRIVE_MONTHLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "${PRIMARY_HDD}/${ARCHIVE}" "$GDRIVE_MONTHLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    # GDrive pruning
    log_msg "Pruning GDrive daily (>${7}d)..."
    prune_rclone "$GDRIVE_DAILY" "7d"

    log_msg "Pruning GDrive weekly (>31d)..."
    prune_rclone "$GDRIVE_WEEKLY" "31d"

    log_msg "Pruning GDrive monthly (>185d)..."
    prune_rclone "$GDRIVE_MONTHLY" "185d"

    # Prune local HDD copies older than 7 days
    log_msg "Pruning local HDD backups (>7d)..."
    prune_local "$PRIMARY_HDD" "${NODE}-backup-*.tgz" 7

    # --- 9. Cross-node push (skips self) -------------------------------------
    for TARGET in "${NODES[@]}"; do
        if [[ "$TARGET" != "$NODE" ]]; then
            log_msg "Pushing cross-backup to ${TARGET}..."
            rsync -ahq --mkpath --info=stats1 \
                  "${PRIMARY_HDD}/${ARCHIVE}" \
                  "root@${TARGET}:${CROSS_PATH}/${NODE}/" >> "$LOG_FILE" 2>&1 \
                || log_msg "  WARNING: Cross-backup to ${TARGET} failed (non-fatal)."
        fi
    done

else
    # Fallback: no local HDD — upload directly to GDrive via rclone
    log_msg "WARNING: Primary HDD not found. Uploading directly to GDrive..."
    rclone --config "$RCLONE_CONF" \
        copy "${LOCAL_TEMP}/${ARCHIVE}" "$GDRIVE_DAILY" \
        --log-level ERROR >> "$LOG_FILE" 2>&1

    if [ "$DOW" = "7" ]; then
        rclone --config "$RCLONE_CONF" \
            copy "${LOCAL_TEMP}/${ARCHIVE}" "$GDRIVE_WEEKLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    if [ "$DOM" = "01" ]; then
        rclone --config "$RCLONE_CONF" \
            copy "${LOCAL_TEMP}/${ARCHIVE}" "$GDRIVE_MONTHLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    log_msg "Pruning GDrive daily (>7d)..."
    prune_rclone "$GDRIVE_DAILY" "7d"

    log_msg "Pruning GDrive weekly (>31d)..."
    prune_rclone "$GDRIVE_WEEKLY" "31d"

    log_msg "Pruning GDrive monthly (>185d)..."
    prune_rclone "$GDRIVE_MONTHLY" "185d"
fi

# Safety net: remove temp archive if it wasn't consumed
rm -f "${LOCAL_TEMP}/${ARCHIVE}"

# --- 10. Cross-backup pruning (incoming archives on this node) ---------------
if [ -d "$CROSS_PATH" ]; then
    log_msg "Pruning incoming cross-backups (>14d)..."
    prune_local "$CROSS_PATH" "*.tgz" 14
fi

# --- 11. Home Assistant backup sync ------------------------------------------
HA_BACKUP_DIR="/home/arrrghhh/.homeassistant/backups/"
GDRIVE_HA_DAILY="${GDRIVE_DAILY}/HA"
GDRIVE_HA_WEEKLY="${GDRIVE_WEEKLY}/HA"
GDRIVE_HA_MONTHLY="${GDRIVE_MONTHLY}/HA"

if [ -d "$HA_BACKUP_DIR" ]; then
    log_msg "Syncing latest HA backup to GDrive daily (${GDRIVE_HA_DAILY})..."
    rclone --config "$RCLONE_CONF" \
        copy "$HA_BACKUP_DIR" "$GDRIVE_HA_DAILY" \
        --max-age 24h --log-level ERROR >> "$LOG_FILE" 2>&1

    if [ "$DOW" = "7" ]; then
        log_msg "Sunday — copying HA backup to weekly (${GDRIVE_HA_WEEKLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "$HA_BACKUP_DIR" "$GDRIVE_HA_WEEKLY" \
            --max-age 24h --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    if [ "$DOM" = "01" ]; then
        log_msg "1st of month — copying HA backup to monthly (${GDRIVE_HA_MONTHLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "$HA_BACKUP_DIR" "$GDRIVE_HA_MONTHLY" \
            --max-age 24h --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    log_msg "Pruning GDrive HA daily (>7d)..."
    prune_rclone "$GDRIVE_HA_DAILY" "7d"

    log_msg "Pruning GDrive HA weekly (>31d)..."
    prune_rclone "$GDRIVE_HA_WEEKLY" "31d"

    log_msg "Pruning GDrive HA monthly (>90d)..."
    prune_rclone "$GDRIVE_HA_MONTHLY" "90d"
fi

# --- 12. Stats ---------------------------------------------------------------
if [ -f "${PRIMARY_HDD}/${ARCHIVE}" ]; then
    final_size_kb=$(du -sk "${PRIMARY_HDD}/${ARCHIVE}" | cut -f1)
    final_size_bytes=$(( final_size_kb * 1024 ))
    pretty_source=$(numfmt --to=iec --suffix=B --format="%.1f" "$TOTAL_SOURCE_SIZE_BYTES")
    pretty_final=$(numfmt --to=iec --suffix=B --format="%.1f" "$final_size_bytes")
    ratio=$(echo "scale=1; ($final_size_bytes / $TOTAL_SOURCE_SIZE_BYTES) * 100" | bc)
    log_msg "-------------------------------------------------------"
    log_msg "Stats | Source: $pretty_source | Archive: $pretty_final | Compression ratio: ${ratio}%"
fi

END_TIME=$(date +%s)
DIFF=$(( END_TIME - START_TIME ))
log_msg "Backup completed successfully in $((DIFF / 60))m $((DIFF % 60))s."

# --- 13. Fix log ownership ---------------------------------------------------
chown -R arrrghhh:arrrghhh "$LOG_DIR"

# --- 14. Monthly log archiving (runs on 1st, after chown) --------------------
if [ "$DOM" = "01" ]; then
    LAST_MONTH=$(date -d "last month" +%Y-%m)
    ARCHIVE_DIR="${LOG_DIR}/archives"
    mkdir -p "$ARCHIVE_DIR"
    log_msg "Archiving logs for ${LAST_MONTH}..."

    shopt -s nullglob
    log_files=( "${LOG_DIR}"/*"${LAST_MONTH}"* )
    shopt -u nullglob

    if [ "${#log_files[@]}" -gt 0 ]; then
        tar -czf "${ARCHIVE_DIR}/backup_logs_${LAST_MONTH}.tgz" \
            -C "$LOG_DIR" "${log_files[@]##*/}"
        find "$LOG_DIR" -maxdepth 1 -name "*${LAST_MONTH}*" -delete
        log_msg "Log archive created: backup_logs_${LAST_MONTH}.tgz"
    else
        log_msg "No logs found for ${LAST_MONTH}; skipping log archive."
    fi

    # Keep 1 year of log archives
    find "${ARCHIVE_DIR}" -name "*.tgz" -mtime +365 -delete
fi