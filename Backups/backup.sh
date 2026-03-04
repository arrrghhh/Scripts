#!/bin/bash

# 1. Identity & Paths
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

tar --warning=no-file-changed "${EXCLUDES[@]}" -czf "${LOCAL_TEMP}/${ARCHIVE}" $BACKUP_FILES

if [ $? -le 1 ]; then
    log_msg "Local archive created successfully."

    if [ -d "/media/backup/Backups/UbuntuServer" ]; then
        log_msg "Primary server detected. Preparing HDD destination."
        mkdir -p "$PRIMARY_HDD"
        mv "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/"
        
        # Point to the specific config file for rclone
        rclone --config "$RCLONE_CONF" copy "${PRIMARY_HDD}/${ARCHIVE}" "gdrive:Backups/ubuntu_backup/$NODE"
        
        find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    else
        log_msg "Secondary/Third server detected. Preparing Cloud Mount."
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