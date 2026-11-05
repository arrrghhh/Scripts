# rclone-gdrive — Google Drive mount + health monitor

Mounts Google Drive at `/media/gdrive` on any host that needs it, with an
hourly health check that can restart the mount on its own.

Two hosts use this today:

| Host          | Mount | Monitor |
|---------------|-------|---------|
| nas           | yes   | yes     |
| summitserver  | yes   | yes     |

The mount runs as `arrrghhh`; the monitor runs from root cron (it restarts a
system service, which `arrrghhh` cannot do without interactive polkit auth).

## Files

| File                                  | Installs to                          |
|---------------------------------------|--------------------------------------|
| `docker/systemd/rclone-gdrive.service`| `/etc/systemd/system/`               |
| `docker/rclone-gdrive/monitor.sh`     | `/usr/local/sbin/rclone-gdrive-monitor.sh` (root:root 755) |
| `docker/systemd/rclone-gdrive-monitor.cron` | `/etc/cron.d/rclone-gdrive-monitor` (root:root 644) |
| `docker/rclone-gdrive/alert.env`      | `~/Scripts/docker/rclone-gdrive/alert.env` (mode 600, **gitignored**) |

`alert.env` is per-host: set `HA_TOKEN_FILE` to that host's token. Everything
else (HA URL/target, SMTP) is shared.

## Prerequisites the script does not set up

- `rclone` with a `gdrive` remote in `/home/arrrghhh/.config/rclone/rclone.conf`
  owned by `arrrghhh`, mode 600. This file belongs to the mount. Do **not** let
  root's rclone write to it — root's backups use `/root/.config/rclone/rclone.conf`
  (see `Backups/README.md`). Mixing them flips ownership to root on the next
  OAuth token refresh and the mount can no longer read its config.
- `user_allow_other` uncommented in `/etc/fuse.conf` (the unit passes
  `--allow-other`).
- Nothing else may write to `/media/gdrive` while the mount is running.

## Deploy

```bash
# 1. config ownership + FUSE
sudo chown arrrghhh:arrrghhh /home/arrrghhh/.config/rclone/rclone.conf
sudo chmod 600 /home/arrrghhh/.config/rclone/rclone.conf
sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf

# 2. mount unit
sudo install -m 644 -o root -g root docker/systemd/rclone-gdrive.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rclone-gdrive.service

# 3. monitor + root cron
sudo install -m 755 -o root -g root docker/rclone-gdrive/monitor.sh /usr/local/sbin/rclone-gdrive-monitor.sh
sudo install -m 644 -o root -g root docker/systemd/rclone-gdrive-monitor.cron /etc/cron.d/rclone-gdrive-monitor

# 4. alert config (secret, not in git)
install -m 600 docker/rclone-gdrive/alert.env ~/Scripts/docker/rclone-gdrive/alert.env

# verify
systemctl is-active rclone-gdrive.service
mount | grep gdrive
ls /media/gdrive | head
```

## How the monitor behaves

Runs at the top of every hour (`/etc/cron.d/rclone-gdrive-monitor`) as root.

- **Healthy** → one line in `/var/log/rclone-gdrive/monitor.log`, no alert.
- **Not mounted** → restarts the service; silent if that works.
- **Mounted but wedged** → probes the mount root with `stat` (20s). A single
  slow probe only logs and re-checks 5s later; a second failure force-unmounts
  (`fusermount -uz`) and restarts the service. Silent if that works.
- **Recovery failed** → sends one alert via `docker/notify.sh` (HA first, SMTP
  fallback) and sets `/var/lib/rclone-gdrive/outage_notified`. Later runs stay
  quiet until the mount is healthy again, so a long outage does not spam. If
  delivery itself fails, the next run retries.

State and logs are root-owned: `/var/log/rclone-gdrive/monitor.log`,
`/var/lib/rclone-gdrive/`.

The probe deliberately avoids `ls`: a readdir of the Drive root can stall for
tens of seconds when Google is slow, which the original `timeout 5 ls` check
reported as a dead mount and answered with a force-unmount.
