#!/bin/bash

# 1. Identity & Paths
START_TIME=$(date +%s)
NODE=$(hostname)
DATE=$(date +%Y-%m-%d)
LOCAL_TEMP="/home/arrrghhh/backups_local"
LOG_DIR="/home/arrrghhh/backup_logs"
LOG_FILE="${LOG_DIR}/backup_${NODE}_${DATE}.log"

# Explicitly point to your user's rclone config so root can see it
RCLONE_CONF="/home/arrrghhh/.config/rclone/rclone.conf"

PRIMARY_HDD="/media/backup/Backups/UbuntuServer/$NODE"
CLOUD_MOUNT="/media/gdrive/Backups/ubuntu_backup/$NODE"

# Ensure log and local temp dirs exist
mkdir -p "$LOCAL_TEMP" "$LOG_DIR"

log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# 2. Targeted Files & Exclusions
BACKUP_FILES="/home /etc /usr/local/bin /var/spool/cron /media/complete/sabnzbd"
EXCLUDES=(
    --exclude="*/backups_local/*"           # STOPS the 1GB recursive backup loop
    --exclude="*/.homeassistant/backups/*"   # Removes redundant HA internal backups
    --exclude="*/.medusa/Logs/*"            # Drops Medusa log history
    --exclude="*/.medusa/cache*"             # Drops Medusa cache/WAL files
    --exclude="*/.deluge/config/supervisord.log*" # Drops Deluge log rotation
    --exclude="*/.git/*"                     # Drops large .git objects
    --exclude="*/.homeassistant/tmp/*"      # Prevents HA temp file bloat
    --exclude="*/pihole-FTL.db"             # Excludes large Pi-hole database
    --exclude="*/sabnzbd/Downloads/*"       # Skips active download data
    --exclude="*/sabnzbd/logs/*"            # Skips SABnzbd log history
    --exclude="*/.cache/*"                  # General app caches
    --exclude="*/.vscode-server/*"          # VS Code binaries/extensions
    --exclude="*/Dropbox/*"                 # Skips cloud-synced data
    --exclude="*/.plex/*"                   # Skips massive Plex metadata
    --exclude="*/.scrypted/*"               # Skips NVR/Camera caches
    --exclude="*/.frigate/model_cache/*"    # Skips AI model caches
    --exclude="*/.homeassistant/home-assistant_v2.db*" # Skips live HA DB
)

# 3. Execution
ARCHIVE="${NODE}-backup-${DATE}.tgz"
log_msg "Starting exhaustive backup for $NODE"

tar --warning=no-file-changed "${EXCLUDES[@]}" \
    --checkpoint=50000 --checkpoint-action=echo="Compressed %u elements..." \
    -czf "${LOCAL_TEMP}/${ARCHIVE}" $BACKUP_FILES >> "$LOG_FILE" 2>&1

if [ $? -le 1 ]; then
    if tar -tzf "${LOCAL_TEMP}/${ARCHIVE}" > /dev/null 2>&1; then
        log_msg "Integrity check passed."
    else
        log_msg "ERROR: Integrity check failed."
        exit 1
    fi

    if [ -d "/media/backup/Backups/UbuntuServer" ]; then
        log_msg "Primary server detected. Syncing to HDD..."
        mkdir -p "$PRIMARY_HDD"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/" >> "$LOG_FILE" 2>&1
        
        log_msg "Syncing to Cloud (Google Drive)..."
        rclone --config "$RCLONE_CONF" copy "${PRIMARY_HDD}/${ARCHIVE}" "gdrive:Backups/ubuntu_backup/$NODE" \
               -v --stats 15s --stats-one-line >> "$LOG_FILE" 2>&1
                    
        find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    else
        log_msg "Secondary server detected. Syncing to Cloud Mount..."
        mkdir -p "$CLOUD_MOUNT"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${CLOUD_MOUNT}/" >> "$LOG_FILE" 2>&1
        find "$CLOUD_MOUNT" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    fi

    log_msg "Syncing latest HA internal backup to GDrive..."
    rclone --config "$RCLONE_CONF" copy /home/arrrghhh/.homeassistant/backups/ "gdrive:Backups/HA_Direct" --max-age 24h >> "$LOG_FILE" 2>&1
    
    # Calculate Duration
    END_TIME=$(date +%s)
    DIFF=$(( END_TIME - START_TIME ))
    log_msg "Backup and pruning completed successfully. Total Duration: $((DIFF / 60))m $((DIFF % 60))s"
else
    log_msg "ERROR: Backup failed for $NODE."
    exit 1
fi

chown -R arrrghhh:arrrghhh "$LOG_DIR"