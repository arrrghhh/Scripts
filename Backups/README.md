# Backups — Ubuntu server multi-tier backup

`backup.sh` creates a daily tar.gz of configured sources and rotates it across
three tiers: **Daily x7 | Weekly x4 (Sunday) | Monthly x12 (1st)**, stored on a
local HDD, in Google Drive (rclone GFS), and pushed to the other servers.

## Files

| File             | Purpose                                              |
|------------------|------------------------------------------------------|
| `backup.sh`      | The backup script (single self-contained file).      |
| `backup.service` | systemd oneshot unit.                                |
| `backup.timer`   | systemd timer — fires daily at 02:30 local.          |

## Deploying on a server

The same `backup.sh` runs unchanged on all three servers; per-server identity
comes from `hostname`. The weekly/monthly promotion is decided inside the
script, so the timer only needs to fire once per day.

```console
# 1. Install the script
sudo install -m 0755 -o root -g root backup.sh /usr/local/sbin/backup.sh

# 2. Install the timer
sudo install -m 0644 backup.service backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer

# 3. Check status / run manually
systemctl status backup.timer
sudo /usr/local/sbin/backup.sh          # manual run (honours the lock)
journalctl -u backup.service            # or read the per-day log in /var/log/backup_logs/
```

Edit `OnCalendar=` in `backup.timer` to change the time. `Persistent=true`
runs the backup after a missed schedule (e.g. machine off overnight).

## Per-server prerequisites

All are assumed to exist already; the script does not set them up:

- `rclone` with a `gdrive` remote in
  `/home/<LOG_RUN_USER>/.config/rclone/rclone.conf`.
- The local HDD mounted at `/media/backup` (the script falls back to direct
  GDrive upload if it is absent).
- SSH aliases for the other two nodes in `/root/.ssh/config`, with
  passwordless `root` access, so cross-backups can be pushed.
- `mail` or `sendmail` if you want failure alerts (`ALERT_TO` set).

## Configuration

Everything lives in the CONFIG section at the top of `backup.sh`:

| Setting            | Default          | Notes                                   |
|--------------------|------------------|-----------------------------------------|
| `LOG_RUN_USER`     | `arrrghhh`       | Owner of logs and rclone/HA paths.      |
| `PRIMARY_BASE`     | `/media/backup/…`| Local HDD root; per-node subfolder.     |
| `SOURCES`          | `/home /etc …`   | Directories to archive.                 |
| `EXCLUDE_PATTERNS` | (list)           | Single source of truth for tar + rsync. |
| `NODES`            | `summitserver nas usrv` | Cross-backup targets (skips self). |
| `ALERT_TO`         | empty            | Email for failure alerts.               |
| `RET_DAILY`        | `7d`             | GDrive daily retention.                 |
| `RET_WEEKLY`       | `28d`            | GDrive weekly retention.                |
| `RET_MONTHLY`      | `365d`           | GDrive monthly retention (~12 copies).  |

## GDrive layout

Tiers are **siblings** — this is deliberate and must stay that way. `rclone
delete` recurses, so if weekly/monthly were nested inside the daily folder the
daily prune would wipe them (the v1 bug). Every prune also passes
`--max-depth 1` so it can never escape its own folder.

```
gdrive:Backups/ubuntu_backup/Rolling/<node>/daily
gdrive:Backups/ubuntu_backup/Rolling/<node>/weekly
gdrive:Backups/ubuntu_backup/Rolling/<node>/monthly
gdrive:Backups/ubuntu_backup/Rolling/<node>/HA/daily
gdrive:Backups/ubuntu_backup/Rolling/<node>/HA/weekly
gdrive:Backups/ubuntu_backup/Rolling/<node>/HA/monthly
```

## Migrating from v1

v1 kept the daily archives at `Rolling/<node>/` (the root) with weekly/monthly
nested inside. v2 uses the same `Rolling/<node>/weekly|monthly` paths (so those
are reused) but moves daily into `Rolling/<node>/daily/`. After the first v2
run, clean up the old root-level daily archives once:

```console
rclone delete gdrive:Backups/ubuntu_backup/Rolling/<node> \
    --max-depth 1 --include '*-backup-*.tgz' --min-age 8d
rclone delete gdrive:Backups/ubuntu_backup/Rolling/<node>/HA \
    --max-depth 1 --include '*.tar' --min-age 8d
```

(repeat for each node; run with `--dry-run` first)

## Restoring

An archive is a standard `.tgz` of `/home`, `/etc`, `/usr/local/bin`, and
`/var/spool/cron`:

```console
tar -tzf backup.tgz | less          # inspect
tar -xzf backup.tgz -C /            # extract (paths relative to root)
```

Recovery copies live in three places: the local HDD (7d), GDrive tiers, and
`cross_backups/<node>/` on the other two servers (14d).
