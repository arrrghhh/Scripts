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
    --exclude="*/.cache/*"
    --exclude="*/.vscode-server/*"
    --exclude="*/Dropbox/*"
    --exclude="*/.plex/*"
    --exclude="*/.scrypted/*"
    --exclude="*/.frigate/model_cache/*"
    --exclude="*/.homeassistant/home-assistant_v2.db*"
    --exclude="*/.homeassistant/tmp/*"
    --exclude="*/pihole-FTL.db"
    --exclude="*/sabnzbd/Downloads/*"
    --exclude="*/sabnzbd/logs/*"
)

# 3. Execution
ARCHIVE="${NODE}-backup-${DATE}.tgz"
log_msg "Starting exhaustive backup for $NODE"

# TAR with progress checkpoints
tar --warning=no-file-changed "${EXCLUDES[@]}" \
    --checkpoint=10000 --checkpoint-action=echo="Compressed %u elements..." \
    -czf "${LOCAL_TEMP}/${ARCHIVE}" $BACKUP_FILES >> "$LOG_FILE" 2>&1

if [ $? -le 1 ]; then
    log_msg "Local archive created successfully."

    if [ -d "/media/backup/Backups/UbuntuServer" ]; then
        log_msg "Primary server detected. Moving to HDD..."
        mkdir -p "$PRIMARY_HDD"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/" >> "$LOG_FILE" 2>&1
        
        log_msg "Syncing to Cloud (Google Drive)..."
        rclone --config "$RCLONE_CONF" copy "${PRIMARY_HDD}/${ARCHIVE}" "gdrive:Backups/ubuntu_backup/$NODE" \
               --stats 30s --stats-one-line >> "$LOG_FILE" 2>&1
                    
        find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    else
        log_msg "Secondary server detected. Moving to Cloud Mount..."
        mkdir -p "$CLOUD_MOUNT"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${CLOUD_MOUNT}/" >> "$LOG_FILE" 2>&1
        find "$CLOUD_MOUNT" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    fi
    
    # Calculate Duration
    END_TIME=$(date +%s)
    DIFF=$(( END_TIME - START_TIME ))
    log_msg "Backup and pruning completed successfully. Total Duration: $((DIFF / 60))m $((DIFF % 60))s"
else
    log_msg "ERROR: Backup failed for $NODE."
    exit 1
fi

chown -R arrrghhh:arrrghhh "$LOG_DIR"