# Backups — Ubuntu server multi-tier backup

`backup.sh` creates a daily compressed tar archive of configured sources and
rotates it across three tiers: **Daily x7 | Weekly x4 (Sunday) | Monthly x12
(1st)**, stored on a local HDD, in Google Drive (rclone GFS), and pushed to the
other servers. By default the archive is `.txz` (xz); see `COMPRESS` below.

## Files

| File             | Purpose                                              |
|------------------|------------------------------------------------------|
| `backup.sh`      | The backup script (single self-contained file).      |
| `backup.service` | systemd oneshot unit.                                |
| `backup.timer`   | systemd timer — daily, per-node `OnCalendar=` override. |

## Deploying on a server

The same `backup.sh` runs unchanged on all servers; per-server identity comes
from `hostname`. The weekly/monthly promotion is decided inside the script, so
the timer only needs to fire once per day.

**Deployment is via git, not file copies.** The servers run the script straight
out of the shared checkout at `/home/arrrghhh/Scripts`, and
`docker-conf-sync@<endpoint>.timer` (every 10 min) fetches and fast-forwards
that checkout:

```console
# On your workstation: edit, commit, push
git commit -am "Backups: ..."
git push origin main

# Servers fast-forward automatically; to force it now:
sudo systemctl start docker-conf-sync@Lakewood.service    # or @SummitHouse / @usrv
```

The systemd unit must point at the checkout, not a copy:

```console
# /etc/systemd/system/backup.service
ExecStart=/bin/bash /home/arrrghhh/Scripts/Backups/backup.sh
```

Do **not** `scp` or `install` the script over the checkout — a modified
working tree blocks `git merge --ff-only`, so the sync timer fails until the
tree is clean. Only if a server is not using the repo does a standalone
install make sense (drop a copy at e.g. `/usr/local/sbin/backup.sh` and point
`ExecStart=` there).

```console
# Check status / run manually
systemctl status backup.timer
sudo systemctl start backup.service     # manual run (honours the lock)
journalctl -u backup.service            # or read the per-day log in /var/log/backup_logs/
```

Edit `OnCalendar=` in `backup.timer` (or a drop-in) to change the time.
`Persistent=true` runs the backup after a missed schedule (e.g. machine off
overnight).

## Per-server prerequisites

All are assumed to exist already; the script does not set them up:

- `rclone` with a `gdrive` remote in `/root/.config/rclone/rclone.conf`
  (the script runs as root, so it uses root's own config; see the note in
  `backup.sh` about not sharing the config with the user's rclone mount).
- The local HDD mounted at `/media/backup` (the script falls back to direct
  GDrive upload if it is absent).
- SSH aliases for the other two nodes in `/root/.ssh/config`, with
  passwordless `root` access, so cross-backups can be pushed.
- `mail` or `sendmail` if you want failure alerts (`ALERT_TO` set).
- The decompressor for `COMPRESS` (`xz` by default; `gzip` or `zstd` if changed).

## Configuration

Everything lives in the CONFIG section at the top of `backup.sh`:

| Setting            | Default          | Notes                                   |
|--------------------|------------------|-----------------------------------------|
| `LOG_RUN_USER`     | `arrrghhh`       | Owner of log and HA paths.              |
| `PRIMARY_BASE`     | `/media/backup/…`| Local HDD root; per-node subfolder.     |
| `SOURCES`          | `/home /etc …`   | Directories to archive.                 |
| `COMPRESS`         | `xz`             | `xz` (`.txz`), `gzip` (`.tgz`), `zstd` (`.tzst`). |
| `EXCLUDE_PATTERNS` | (list)           | Single source of truth for tar + rsync. |
| `NODES`            | `summitserver nas` | Cross-backup targets (skips self).    |
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

An archive is a standard tar of `/home`, `/etc`, `/root`, `/usr/local/bin`,
`/var/lib/samba`, and `/var/spool/cron`, compressed according to `COMPRESS`.
Old `.tgz` archives from before the xz switch remain restorable and are pruned
by the normal retention rules — the script prunes all three extensions.

> **Secrets:** archives now include `/root` (root's SSH private keys and the
> rclone OAuth token) and `/var/lib/samba` (the Samba passdb and machine
> secrets), in addition to the `/etc/shadow`, SSH host keys, and app `.env`
> files that were already included. The local HDD, GDrive, and cross-backup
> copies are **not encrypted** — protect those destinations accordingly.


```console
# xz (default)
tar -tJf backup.txz | less          # inspect
tar -xJf backup.txz -C /            # extract (paths relative to root)

# gzip (legacy archives)
tar -tzf backup.tgz | less
tar -xzf backup.tgz -C /

# zstd
tar --use-compress-program=zstd -tf backup.tzst | less
tar --use-compress-program=zstd -xf backup.tzst -C /
```

Recovery copies live in three places: the local HDD (7d), GDrive tiers, and
`cross_backups/<node>/` on the other two servers (14d).
