# Frappe CRM on Coolify

Production stack for [frappe/crm](https://github.com/frappe/crm) v1.92.0,
deployed as a Coolify docker-compose application.

The stack is the upstream `frappe/frappe_docker` production composition
(`backend`, `frontend`, `websocket`, two queue workers, `scheduler`,
MariaDB, two Redis instances). Coolify's Traefik terminates TLS and routes to
`frontend:8080`; nothing here publishes a host port or writes proxy labels.

## Image

`frappe-crm:1.92.0` is built on the Coolify host by `scripts/build-image.sh`
using `frappe_docker/images/layered/Containerfile` with `apps.json` pointing at
`frappe/crm@v1.92.0` (Frappe Framework v15).

We do **not** pull `ghcr.io/frappe/crm:v1.92.0`: as of 2026-11-04 that image
contains only the framework. Its release workflow passes `APPS_JSON_BASE64` as
a build argument, but the Containerfile now reads `apps.json` from a BuildKit
secret mount, so the app list is silently ignored. Verified on the host:

```console
$ docker run --rm --entrypoint bash ghcr.io/frappe/crm:v1.92.0 -c 'ls apps'
frappe
```

Rebuild after a version bump, then redeploy from Coolify:

```bash
CRM_BRANCH=v1.93.0 TAG=1.93.0 ./scripts/build-image.sh
```

The compose file pins the local tag and sets `pull_policy: never`.

## Environment contract

Set these in Coolify (App → Environment Variables). Nothing secret is stored
in this repository.

| Variable | Required | Meaning |
| --- | --- | --- |
| `CUSTOM_IMAGE` | no | defaults to the locally built `frappe-crm` |
| `CUSTOM_TAG` | no | defaults to the pinned release `1.92.0` |
| `DB_PASSWORD` | **yes** | MariaDB root password |
| `SITE_NAME` | **yes** | Frappe site name, equal to the public hostname |
| `ADMIN_PASSWORD` | **yes** | Administrator password set at site creation |
| `BACKUP_INTERVAL_SECONDS` | no | default 86400 |
| `BACKUP_KEEP_DAYS` | no | default 7 |
| `GUNICORN_WORKERS` / `GUNICORN_THREADS` | no | default 2 / 4 |

## First deploy

1. Coolify app: `docker-compose` build pack, branch `main`,
   compose file `/docker-compose.yaml`, domain on the **frontend** service.
2. Set the environment variables above, then deploy.
3. `configurator` writes the bench config, `init-site` runs
   `bench new-site <SITE_NAME> --install-app crm` (2–4 minutes on first boot),
   then the workers and nginx come up. The site is served at
   `https://<SITE_NAME>/crm`.

`init-site` is idempotent: on every later deploy it sees the site and exits 0.

## Persistent storage

| Volume | Contents |
| --- | --- |
| `sites` | site directory: database credentials, private files, uploaded files, bench backups |
| `db-data` | MariaDB data directory |
| `redis-queue-data` | Redis queue persistence |

Named volumes survive redeploys. They live on the Coolify host, so the host's
nightly restic snapshot to B2 covers them; the independent logical dump in
`/var/backups/coolify-dumps` also picks up this stack's MariaDB container.

## Backups

`backup` runs `bench --site <SITE_NAME> backup --with-files` 15 minutes after
the stack starts and then every `BACKUP_INTERVAL_SECONDS`, keeping
`BACKUP_KEEP_DAYS` days of database + files archives under
`sites/<SITE_NAME>/private/backups/`.

Restore into the same site:

```bash
docker exec -it <backend-container> bash
bench --site <SITE_NAME> --force restore \
  sites/<SITE_NAME>/private/backups/<timestamp>-database.sql.gz \
  --with-public-files sites/<SITE_NAME>/private/backups/<timestamp>-files.tar \
  --with-private-files sites/<SITE_NAME>/private/backups/<timestamp>-private-files.tar
```

## Email (two-way)

Frappe sends and receives through an **Email Account** (Desk → Email Account):
SMTP for outgoing, IMAP for incoming, with the account marked default outgoing
and default incoming. The CRM-side custom field
`create_lead_from_incoming_email` turns first-contact mail into a CRM Lead;
replies are attached to the existing lead/deal thread by sender address.

## Operations

```bash
bench --site <SITE_NAME> migrate            # after an image bump
bench --site <SITE_NAME> clear-cache
bench --site <SITE_NAME> backup --with-files
```

Site config lives in `sites/<SITE_NAME>/site_config.json` on the `sites`
volume (inside the containers).
