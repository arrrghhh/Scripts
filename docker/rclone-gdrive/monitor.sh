#!/usr/bin/env bash
#
# rclone-gdrive-monitor.sh — hourly health check + auto-recovery for the
# rclone Google Drive mount on the nas host.
#
# Runs from ROOT cron (/etc/cron.d/rclone-gdrive-monitor) so it can restart
# the system service without interactive polkit auth.
#
# Design goals:
#   * silent when healthy (no daily spam)
#   * silent when auto-recovery succeeds (self-heal, no alert)
#   * ONE notification per outage: alert only when recovery fails, then stay
#     quiet until the mount is healthy again (flag cleared).
#   * if the alert cannot be delivered, retry next hour (don't falsely mark
#     the outage as notified).
#
# Notifications go through /home/arrrghhh/Scripts/docker/notify.sh, the same
# path used by the Docker alerts (HA first, SMTP fallback, opt-in via
# docker/rclone-gdrive/alert.env).
#
set -uo pipefail

# Cron has a minimal PATH; set a sane one so systemctl/mountpoint are found.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MOUNT_POINT="/media/gdrive"
SERVICE_NAME="rclone-gdrive.service"

LOG_FILE="/var/log/rclone-gdrive/monitor.log"
STATE_DIR="/var/lib/rclone-gdrive"
STATE_FILE="${STATE_DIR}/last_check_hour"
NOTIFY_FLAG="${STATE_DIR}/outage_notified"
LOCK_FILE="${RCLONE_MONITOR_LOCK:-/run/rclone-gdrive-monitor.lock}"

# alert plumbing lives in arrrghhh's home; notify.sh resolves alert.env
# relative to its own directory (docker/rclone-gdrive/alert.env).
NOTIFY_SCRIPT="/home/arrrghhh/Scripts/docker/notify.sh"
NOTIFY_ENDPOINT="rclone-gdrive"

# --- logging ---------------------------------------------------------------

log_msg() {
    local level="$1"; shift
    local ts
    ts=$(date '+%F %T')
    printf '[%s] %s: %s\n' "$ts" "$level" "$*" >> "$LOG_FILE"
    logger -t rclone-gdrive-monitor "${level}: $*" 2>/dev/null || true
}
log_info() { log_msg INFO "$@"; }
log_warn() { log_msg WARN "$@"; }
log_err()  { log_msg ERR  "$@"; }

# --- checks ----------------------------------------------------------------

is_mounted() {
    mountpoint -q "$MOUNT_POINT" 2>/dev/null || mount | grep -q " $MOUNT_POINT "
}

is_accessible() {
    # FUSE can report "mounted" yet be wedged. A getattr on the mount root
    # (stat) proves liveness without a full Drive readdir, which can be slow
    # for reasons that have nothing to do with a dead mount. Generous timeout
    # for the same reason; callers re-check before declaring a wedge.
    local probe_timeout="${1:-20}"
    timeout "$probe_timeout" stat "$MOUNT_POINT" >/dev/null 2>&1
}

# --- notification ----------------------------------------------------------

notify_on_failure() {
    local subject="$1" body="$2"

    if [ -f "$NOTIFY_FLAG" ]; then
        log_info "Outage already notified; suppressing duplicate alert"
        return 0
    fi

    # notify.sh exits 0 only if a channel succeeded (HA or SMTP), 1 otherwise.
    if bash "$NOTIFY_SCRIPT" "$NOTIFY_ENDPOINT" "$subject" "$body" >>"$LOG_FILE" 2>&1; then
        touch "$NOTIFY_FLAG"
        log_info "Failure notification sent via notify.sh"
    else
        log_err "Failure notification could NOT be delivered (will retry next run)"
    fi
}

# --- recovery --------------------------------------------------------------

attempt_recovery() {
    local reason="$1" recover_cmd="$2"

    log_warn "$reason — attempting auto-recovery"

    if eval "$recover_cmd"; then
        sleep 10
        if is_mounted && is_accessible; then
            log_info "Recovery OK: mount restored at $MOUNT_POINT"
            rm -f "$NOTIFY_FLAG"   # outage resolved
            return 0
        fi
        log_err "Recovery FAILED: mount still not accessible after restart"
        return 1
    fi

    log_err "Recovery FAILED: could not restart $SERVICE_NAME"
    return 1
}

# --- single-run guard ------------------------------------------------------

already_checked() {
    [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$(date +%H)" ]
}
record_check() { date +%H > "$STATE_FILE"; }

# --- main ------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"

# flock: overlap protection without leaving stale lock files behind
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_warn "Another monitor run holds the lock; skipping"
    exit 0
fi

if already_checked; then
    exit 0
fi
record_check

if ! is_mounted; then
    attempt_recovery \
        "MOUNT NOT PRESENT at $MOUNT_POINT" \
        "systemctl restart $SERVICE_NAME" \
    || notify_on_failure \
        "rclone-gdrive mount DOWN (recovery failed)" \
        "Mount $MOUNT_POINT is absent and ${SERVICE_NAME} would not come back up."

elif ! is_accessible 20; then
    # One slow probe is not proof of a wedge: Google can stall a getattr for
    # tens of seconds without the mount being dead. Confirm before tearing it
    # down, so a busy mount is not force-unmounted for no reason.
    log_warn "Mount probe timed out at $MOUNT_POINT; re-checking in 5s"
    sleep 5
    if ! is_accessible 20; then
        attempt_recovery \
            "MOUNT PRESENT but UNRESPONSIVE at $MOUNT_POINT" \
            "fusermount -uz $MOUNT_POINT 2>/dev/null; systemctl restart $SERVICE_NAME" \
        || notify_on_failure \
            "rclone-gdrive mount WEDGED (recovery failed)" \
            "Mount $MOUNT_POINT is present but unresponsive; force-remount also failed."
    else
        log_info "Mount healthy at $MOUNT_POINT (slow first probe)"
        rm -f "$NOTIFY_FLAG"
    fi

else
    log_info "Mount healthy at $MOUNT_POINT"
    rm -f "$NOTIFY_FLAG"
fi

exit 0
