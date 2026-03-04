#!/bin/bash

# 1. Identity & Paths
NODE=$(hostname)
DATE=$(date +%Y-%m-%d)
LOCAL_TEMP="/home/arrrghhh/backups_local"
LOG_DIR="/home/arrrghhh/backup_logs"
LOG_FILE="${LOG_DIR}/backup_${NODE}_${DATE}.log"

# Define the Local HDD path (Primary only) and the Cloud Mount path
PRIMARY_HDD="/media/backup/Backups/UbuntuServer/$NODE"
CLOUD_MOUNT="/media/gdrive/Backups/ubuntu_backup/$NODE"

mkdir -p "$LOCAL_TEMP" "$LOG_DIR"

log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# 2. Precision Exclusions
EXCLUDES=(
    --exclude="*/.cache"
    --exclude="*/.vscode-server"
    --exclude="*/Dropbox"
    --exclude="*/.plex"
    --exclude="*/.scrypted"
    --exclude="*/.frigate/model_cache"
    --exclude="*/.homeassistant/home-assistant_v2.db*"
    --exclude="*/.homeassistant/tmp"
    --exclude="*/sabnzbd/Downloads"
    --exclude="*/sabnzbd/logs"
)

# 3. Execution
BACKUP_FILES="/home /etc /usr/local/bin /var/spool/cron /media/complete/sabnzbd"
ARCHIVE="${NODE}-backup-${DATE}.tgz"

log_msg "Starting backup for $NODE"

# Step A: Create the archive locally for speed and reliability
tar --warning=no-file-changed "${EXCLUDES[@]}" -czf "${LOCAL_TEMP}/${ARCHIVE}" $BACKUP_FILES

if [ $? -le 1 ]; then
    log_msg "Local archive created successfully."

    # Step B: Determine Destination and Sync
    if [ -d "/media/backup/Backups/UbuntuServer" ]; then
        # PRIMARY SERVER LOGIC: Move to HDD, then Copy to Cloud
        log_msg "Primary server detected. Moving to HDD and syncing to Cloud."
        mv "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/"
        
        # Use rclone to push the new file to Google Drive
        rclone copy "${PRIMARY_HDD}/${ARCHIVE}" "gdrive:Backups/ubuntu_backup/$NODE"
        
        # Cleanup HDD (Keep 7 days)
        find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    else
        # SECONDARY SERVER LOGIC: Move directly to Cloud Mount
        log_msg "Secondary/Third server detected. Moving to Cloud Mount."
        mkdir -p "$CLOUD_MOUNT"
        mv "${LOCAL_TEMP}/${ARCHIVE}" "${CLOUD_MOUNT}/"
        
        # Cleanup Cloud Mount (Keep 7 days)
        find "$CLOUD_MOUNT" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    fi
    
    log_msg "Backup and pruning completed successfully."
else
    log_msg "ERROR: Backup failed for $NODE."
    exit 1
fi

chown -R arrrghhh:arrrghhh "$LOG_DIR"