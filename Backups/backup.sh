#!/bin/bash
# =============================================================================
# backup.sh — Multi-tier backup: local HDD + GDrive GFS rotation
#             Daily x7 | Weekly x4 (Sun) | Monthly x6 (1st)
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
CLOUD_MOUNT="/media/gdrive/Backups/ubuntu_backup/${NODE}"
CROSS_PATH="${PRIMARY_BASE}/cross_backups"

# GDrive paths
GDRIVE_DAILY="gdrive:Backups/ubuntu_backup/${NODE}"
GDRIVE_WEEKLY="gdrive:Backups/Weekly/${NODE}"
GDRIVE_MONTHLY="gdrive:Backups/Monthly/${NODE}"

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

# --- 3. Logging helper -------------------------------------------------------
log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

# Trap unexpected errors and report line number
trap 'log_msg "ERROR: Unexpected failure at line ${LINENO}. Exiting."; exit 1' ERR

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

EXCLUDES=(
    --exclude="*/backups_local/*"                       # Stops recursive backup loop
    --exclude="*/.homeassistant/backups/*"              # Redundant HA internal backups
    --exclude="*/.homeassistant/tts/*"                  # Cached text-to-speech audio
    --exclude="*/.homeassistant/tmp/*"                  # HA temp file bloat
    --exclude="*/.homeassistant/home-assistant_v2.db*"  # Live HA DB (often corrupted in tar)
    --exclude="*/.medusa/Logs/*"                        # Medusa log history
    --exclude="*/.medusa/cache*"                        # Medusa cache/WAL files
    --exclude="*/.deluge/config/supervisord.log*"       # Deluge log rotation
    --exclude="*/.deluge/supervisord.log*"              # Deluge log rotation
    --exclude="*/.git/*"                                # Large .git objects
    --exclude="*/pihole-FTL.db"                         # Large Pi-hole database
    --exclude="*/.sabnzbd/Downloads/*"                  # Active download data
    --exclude="*/.sabnzbd/logs/*"                       # SABnzbd log history
    --exclude="*/.sabnzbd/*/logs/*"                     # SABnzbd nested logs
    --exclude="*/.nginxproxmgr/logs/*"                  # Nginx Proxy Manager logs
    --exclude="*/.cache/*"                              # General app caches
    --exclude="*/.vscode-server/*"                      # VS Code binaries/extensions
    --exclude="*/Dropbox/*"                             # Cloud-synced data
    --exclude="*/.plex/*"                               # Plex metadata
    --exclude="*/.scrypted/*"                           # NVR/camera caches
    --exclude="*/.frigate/model_cache/*"                # Frigate AI model caches
    --exclude="*/*.db-wal"                              # SQLite WAL files
    --exclude="*/*.db-shm"                              # SQLite shared memory files
    --exclude="*.js.map"                                # JS source maps
)

# --- 5. Source inventory (size estimation) -----------------------------------
# Note: du doesn't accept tar-style --exclude flags; sizes are pre-exclusion estimates.
TOTAL_SOURCE_SIZE_KB=0
BACKUP_FILES=()

log_msg "Source inventory:"
for dir in "${SOURCES[@]}"; do
    if [ -d "$dir" ]; then
        size_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
        TOTAL_SOURCE_SIZE_KB=$((TOTAL_SOURCE_SIZE_KB + size_kb))
        human_size=$(numfmt --to=iec --suffix=B --format="%.1f" $((size_kb * 1024)))
        log_msg "  [+] $dir (~${human_size}, pre-exclusion estimate)"
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

# --- 7. Distribute to local HDD or cloud mount fallback ----------------------
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

    if [ "$DOW" = "7" ]; then
        log_msg "Sunday — copying to GDrive weekly (${GDRIVE_WEEKLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "${GDRIVE_DAILY}/${ARCHIVE}" "$GDRIVE_WEEKLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    if [ "$DOM" = "01" ]; then
        log_msg "1st of month — copying to GDrive monthly (${GDRIVE_MONTHLY})..."
        rclone --config "$RCLONE_CONF" \
            copy "${GDRIVE_DAILY}/${ARCHIVE}" "$GDRIVE_MONTHLY" \
            --log-level ERROR >> "$LOG_FILE" 2>&1
    fi

    # GDrive pruning
    log_msg "Pruning GDrive tiers..."
    rclone --config "$RCLONE_CONF" delete "$GDRIVE_DAILY"   --min-age 7d   >> "$LOG_FILE" 2>&1
    rclone --config "$RCLONE_CONF" delete "$GDRIVE_WEEKLY"  --min-age 31d  >> "$LOG_FILE" 2>&1
    rclone --config "$RCLONE_CONF" delete "$GDRIVE_MONTHLY" --min-age 185d >> "$LOG_FILE" 2>&1

    # Prune local HDD copies older than 7 days
    log_msg "Pruning local HDD backups older than 7 days..."
    find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete

    # --- 9. Cross-node push (skips self) -------------------------------------
    for TARGET in "${NODES[@]}"; do
        if [[ "$TARGET" != "$NODE" ]]; then
            log_msg "Pushing cross-backup to ${TARGET}..."
            # --mkpath requires rsync >= 3.2.3; falls back gracefully on older versions
            rsync -ahq --mkpath --info=stats1 \
                  "${PRIMARY_HDD}/${ARCHIVE}" \
                  "root@${TARGET}:${CROSS_PATH}/${NODE}/" >> "$LOG_FILE" 2>&1 \
                || log_msg "  WARNING: Cross-backup to ${TARGET} failed (non-fatal)."
        fi
    done

else
    # Fallback: no local HDD — rsync straight to mounted GDrive
    log_msg "WARNING: Primary HDD not found. Falling back to cloud mount..."
    mkdir -p "$CLOUD_MOUNT"
    rsync -ah --remove-source-files --info=stats1 \
          "${LOCAL_TEMP}/${ARCHIVE}" "${CLOUD_MOUNT}/" >> "$LOG_FILE" 2>&1
    find "$CLOUD_MOUNT" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
fi

# Safety net: remove temp archive if rsync didn't consume it
rm -f "${LOCAL_TEMP}/${ARCHIVE}"

# --- 10. Cross-backup pruning (incoming archives on this node) ---------------
if [ -d "$CROSS_PATH" ]; then
    log_msg "Pruning old incoming cross-backups (>14 days)..."
    find "$CROSS_PATH" -name "*.tgz" -mtime +14 -delete
fi

# --- 11. Home Assistant backup sync ------------------------------------------
HA_BACKUP_DIR="/home/arrrghhh/.homeassistant/backups/"
if [ -d "$HA_BACKUP_DIR" ]; then
    log_msg "Syncing latest HA backup to GDrive (max-age 24h)..."
    rclone --config "$RCLONE_CONF" \
        copy "$HA_BACKUP_DIR" "gdrive:Backups/HA_Direct" \
        --max-age 24h --log-level ERROR >> "$LOG_FILE" 2>&1
fi

# --- 12. Stats ---------------------------------------------------------------
if [ -f "${PRIMARY_HDD}/${ARCHIVE}" ]; then
    final_size_kb=$(du -sk "${PRIMARY_HDD}/${ARCHIVE}" | cut -f1)
    pretty_source=$(numfmt --to=iec --suffix=B --format="%.1f" $((TOTAL_SOURCE_SIZE_KB * 1024)))
    pretty_final=$(numfmt --to=iec --suffix=B --format="%.1f" $((final_size_kb * 1024)))
    ratio=$(echo "scale=1; ($final_size_kb / $TOTAL_SOURCE_SIZE_KB) * 100" | bc)
    log_msg "-------------------------------------------------------"
    log_msg "Stats | Source: $pretty_source | Archive: $pretty_final | Compression: ${ratio}%"
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