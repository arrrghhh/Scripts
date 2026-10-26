# docker/ — live Docker Compose config per endpoint

This directory is the **source of truth** for the Docker Compose files that run on
each endpoint. Hosts pull from this repo; Google Drive is no longer a deploy path.

| Directory      | Host                        | Compose project | Notes |
|----------------|-----------------------------|-----------------|-------|
| `usrv/`        | usrv (192.168.0.10)         | `docker`        | pihole, nginx-proxy-manager |
| `Lakewood/`    | nas (192.168.0.99)          | `docker`        | HA, Plex, *arr stack, MQTT, Matter |
| `SummitHouse/` | summitserver (192.168.1.3)  | `summithouse`   | HA, pihole, Frigate, NPM, MQTT, Matter, Itron |

Each endpoint directory contains:

```
docker-compose.yml   # top-level: name: <project> — pins project identity to the file
.env.example         # key names only, no values
.env                 # gitignored, mode 600, created by hand on the host
```

Shared by every endpoint:

```
conf-sync.sh         # fetch + validate + ff-only merge, takes <endpoint>
dockerupdate.sh      # nightly pull-retry + up -d, takes <endpoint>
```

`name:` matters: without it Compose derives the project name from the *directory*
basename. If the checkout lives somewhere other than the original path, you get a
second project (`summithouse-1`), duplicate containers and `container_name` conflicts.

## Secrets

Secrets live only in each host's `.env`, never in git:

| Endpoint    | Keys |
|-------------|------|
| usrv        | `WEBPASSWORD` |
| Lakewood    | `VPN_USER`, `VPN_PASS` |
| SummitHouse | `WEBPASSWORD`, `FRIGATE_RTSP_PASSWORD`, `PLUS_API_KEY` |

The compose files use `${KEY:?message}` so a missing `.env` **fails the config**
instead of silently starting pihole with an empty admin password.

`docker/.gitignore` ignores `**/.env`; keep the root `.gitignore` covering it too.

## Host layout

```
/home/arrrghhh/docker-compose/                      # git clone of Scripts.git
└── docker/<Endpoint>/docker-compose.yml
    docker/<Endpoint>/.env                   # mode 600, gitignored
```
`/home/arrrghhh` is covered by `backup.timer`, so `.env` rides along in the backup —
it is the one file that cannot be recovered from git.

## Bootstrap / re-bootstrap a host

```bash
git clone https://github.com/arrrghhh/Scripts.git /home/arrrghhh/docker-compose
# create /home/arrrghhh/docker-compose/docker/<Endpoint>/.env, mode 600, with the keys above
chmod 600 /home/arrrghhh/docker-compose/docker/<Endpoint>/.env

# validate before touching containers
cd /home/arrrghhh/docker-compose/docker/<Endpoint>
docker compose config -q

# recreate in place — same project name + container_name means no duplicates
docker compose up -d --remove-orphans
```

Then install the units (replace `<Endpoint>`):

```bash
sudo cp docker/systemd/docker-conf-sync@.service \
        docker/systemd/docker-conf-sync@.timer \
        docker/systemd/docker-update@.service \
        docker/systemd/docker-update@.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-conf-sync@<Endpoint>.timer
sudo systemctl enable --now docker-update@<Endpoint>.timer
```

Remove the old non-templated `docker-update.service` / `.timer` if present.

## How a change propagates

1. `docker-conf-sync@<Endpoint>.timer` fires every 10 minutes.
2. `conf-sync.sh` fetches `origin/main`, renders the **candidate** compose against
   the live `.env`, and runs `docker compose config -q` plus `bash -n` on the
   update script.
3. Only if both pass does it `git merge --ff-only origin/main`.

A broken commit is rejected, the previous files stay live, and the unit fails
visibly. Files are updated within 10 minutes; containers pick them up at the next
`docker-update` run (00:00 America/Denver) or a manual `docker compose up -d`.

## Revert

```bash
cd /home/arrrghhh/docker-compose
git log --oneline -- docker/<Endpoint>
git revert <bad-commit>   # or: git reset --hard <good-commit> — then push
```

The next sync cycle validates and applies it. If the checkout must be forced back
without a push, `git reset --hard <sha>` on the host is safe as long as the commit
is an ancestor of `origin/main`; otherwise the sync unit will report divergence.

## Alerting

Both `docker-conf-sync@.service` and `docker-update@.service` currently have **no
`OnFailure=`**. The Oct 2026 incident (nine silent nightly failures) is exactly
what that allows. Add the same alert hook used for backups once one exists.
