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

PRIMARY_BASE="/media/backup/Backups/UbuntuServer"
PRIMARY_HDD="${PRIMARY_BASE}/$NODE"
CLOUD_MOUNT="/media/gdrive/Backups/ubuntu_backup/$NODE"
CROSS_PATH="/media/backup/Backups/UbuntuServer/cross_backups"

# Use the aliases defined in your /root/.ssh/config
NODES=(
    "summithouse"
    "nas"
    "usrv"
)

# Ensure log and local temp dirs exist
mkdir -p "$LOCAL_TEMP" "$LOG_DIR"

log_msg() { echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# 2. Targeted Files & Exclusions
BACKUP_FILES="/home /etc /usr/local/bin /var/spool/cron /media/complete/sabnzbd"
EXCLUDES=(
    --exclude="*/backups_local/*"                       # STOPS the 1GB recursive backup loop
    --exclude="*/.homeassistant/backups/*"              # Removes redundant HA internal backups
    --exclude="*/.homeassistant/tts/*"                  # Removes cached text-to-speech audio
    --exclude="*/.homeassistant/tmp/*"                  # Prevents HA temp file bloat
    --exclude="*/.homeassistant/home-assistant_v2.db*"  # Skips live HA DB (often corrupted in tar)
    --exclude="*/.medusa/Logs/*"                        # Drops Medusa log history
    --exclude="*/.medusa/cache*"                        # Drops Medusa cache/WAL files
    --exclude="*/.deluge/config/supervisord.log*"       # Drops Deluge log rotation
    --exclude="*/.git/*"                                # Drops large .git objects
    --exclude="*/pihole-FTL.db"                         # Excludes large Pi-hole database
    --exclude="*/sabnzbd/Downloads/*"                   # Skips active download data
    --exclude="*/sabnzbd/logs/*"                        # Skips SABnzbd log history
    --exclude="*/.cache/*"                              # General app caches
    --exclude="*/.vscode-server/*"                      # VS Code binaries/extensions
    --exclude="*/Dropbox/*"                             # Skips cloud-synced data
    --exclude="*/.plex/*"                               # Skips massive Plex metadata
    --exclude="*/.scrypted/*"                           # Skips NVR/Camera caches
    --exclude="*/.frigate/model_cache/*"                # Skips AI model caches
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

    # Check for the primary mount point using the variable
    if [ -d "$PRIMARY_BASE" ]; then
        log_msg "Primary storage ready. Syncing to HDD..."
        mkdir -p "$PRIMARY_HDD"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${PRIMARY_HDD}/" >> "$LOG_FILE" 2>&1
        
        log_msg "Syncing to Cloud (Google Drive)..."
        rclone --config "$RCLONE_CONF" copy "${PRIMARY_HDD}/${ARCHIVE}" "gdrive:Backups/ubuntu_backup/$NODE" \
               -v --stats 15s --stats-one-line >> "$LOG_FILE" 2>&1
                    
        find "$PRIMARY_HDD" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
        
        # Cross-Backup Push (skips self)
        for TARGET in "${NODES[@]}"; do
            if [[ "$TARGET" != "$NODE" ]]; then
                log_msg "Pushing cross-backup to $TARGET..."
                rsync -a "${PRIMARY_HDD}/${ARCHIVE}" "root@${TARGET}:${CROSS_PATH}/${NODE}/" >> "$LOG_FILE" 2>&1
            fi
        done
    else
        log_msg "Primary storage missing. Syncing to Cloud Mount..."
        mkdir -p "$CLOUD_MOUNT"
        rsync -a --remove-source-files --stats "${LOCAL_TEMP}/${ARCHIVE}" "${CLOUD_MOUNT}/" >> "$LOG_FILE" 2>&1
        find "$CLOUD_MOUNT" -name "${NODE}-backup-*.tgz" -mtime +7 -delete
    fi

    # Cleanup any incoming cross-backups locally
    if [ -d "$CROSS_PATH" ]; then
        log_msg "Cleaning up old incoming cross-backups..."
        find "$CROSS_PATH" -name "*.tgz" -mtime +7 -delete
    fi

    # Conditional HA Sync
    if [ -d "/home/arrrghhh/.homeassistant/backups/" ]; then
        log_msg "Syncing latest HA internal backup to GDrive..."
        rclone --config "$RCLONE_CONF" copy /home/arrrghhh/.homeassistant/backups/ "gdrive:Backups/HA_Direct" --max-age 24h >> "$LOG_FILE" 2>&1
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