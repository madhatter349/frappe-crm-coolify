# Frappe CRM on Coolify

Production stack for [frappe/crm](https://github.com/frappe/crm) v1.92.0,
deployed as a Coolify docker-compose application.

The stack is the upstream `frappe/frappe_docker` production composition
(`backend`, `frontend`, `websocket`, two queue workers, `scheduler`,
MariaDB, two Redis instances). Coolify's Traefik terminates TLS and routes to
`frontend:8080`; nothing here publishes a host port or writes proxy labels.

## Image

`frappe-crm:1.92.0-v16` is built on the Coolify host by `scripts/build-image.sh`
using `frappe_docker/images/layered/Containerfile` with `apps.json` pointing at
`frappe/crm@v1.92.0` plus `frappe/flow@develop`, on Frappe Framework **v16**
(required for the built-in MCP server and the AI Agents settings).

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
CRM_BRANCH=v1.93.0 TAG=1.93.0-v16 ./scripts/build-image.sh
# without Flow: FLOW_BRANCH="" TAG=1.92.0-v16 ./scripts/build-image.sh
```

The `init-site` service runs `bench --site <site> migrate` on every deploy, so a
site carried across an image bump (v15 → v16) is migrated by the same deploy
that swaps the image.

The compose file pins the local tag and sets `pull_policy: never`.

## This deployment

| | |
| --- | --- |
| URL | `https://frappe.forefrontinvestors.com` |
| Login page | `https://frappe.forefrontinvestors.com/login` |
| CRM app | `https://frappe.forefrontinvestors.com/crm` (login required; guests get 403 by design) |
| Coolify app | `frappe-crm` (uuid `adtxhdv8afl5pynoc2pr1yfy`), project `Frappe CRM` |
| Site name | `frappe.forefrontinvestors.com` (same as the hostname; Frappe resolves by Host) |
| Stack | Frappe Framework 15.126.0 + crm 1.92.0 |
| Mailbox | `josh@forefrontinvestors.com` via Purelymail, IMAP + SMTP |

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

## AI agents (MCP + opencode + Flow)

Frappe v16 ships an MCP server at `/api/v2/mcp` (Streamable HTTP, 13 tools,
runs as the authenticated user, OAuth2 or `Authorization: token KEY:SECRET`).
It is enabled in **System Settings → AI Agents** (Enable MCP, Server Name,
Agent Instructions); `scripts/site-setup.py` turns it on and writes the site
guidance.

`opencode.json` in this repo points opencode at **DeepSeek V4.1 Flash**
(`deepseek/deepseek-flash`) and registers the MCP endpoint:

```bash
export DEEPSEEK_API_KEY=sk-...        # DeepSeek platform key
export FRAPPE_MCP_AUTH="token <api_key>:<api_secret>"
opencode                              # project config is picked up automatically
```

The agent runs as **`agent@forefrontinvestors.com`** (Sales Manager role, no
Desk login), so MCP can do exactly what a salesperson can do and nothing more.
`scripts/site-setup.py` sets the MCP fields; the API user and keys are created
once per install (see "Agent account" below). Rotate a key by generating a new
one on the User record; the old one stops working immediately.

`agents/AGENTS.md` is the agent brief: CRM data model, the operations that must
go through whitelisted methods (`convert_to_deal`), and the "ask before writing"
rules. The API user behind `FRAPPE_MCP_AUTH` should be a dedicated Sales Manager
account, not Administrator — MCP can only do what that user can do.

**Flow** (installed with the image) is the in-site assistant: Ctrl/Cmd+I in the
Desk, agents, tools, triggers and RAG knowledge bases. It needs an LLM
credential: add a **Flow Provider** (provider `deepseek`, base URL
`https://api.deepseek.com`, API key) and a **Flow Model** with model id
`deepseek/deepseek-flash`.

## Agent account

| | |
| --- | --- |
| User | `agent@forefrontinvestors.com` — System User, role **Sales Manager**, no Desk login |
| Auth | `Authorization: token <api_key>:<api_secret>` against `/api/v2/mcp` |

Create or rotate it in the Desk (User → API Access → Generate Keys) or with:

```bash
bench --site <site> execute frappe.client.insert --args \
  '[{"doctype": "User", "email": "agent@example.com", "first_name": "Agent", "user_type": "System User"}]'
```

MCP discovery (`search_doctypes`, `get_doctype_schema`) returns metadata to any
authenticated user; every document read/write is checked against the agent's
roles, so keep the account narrow and never use Administrator.

## Scheduler

The `scheduler` service runs a 60-second ticker that calls
`frappe.utils.scheduler.enqueue_events` for the site. Upstream starts
`bench schedule`, whose in-process loop was observed here holding its lock but
never enqueuing (no jobs, no log line) after a restart; the external ticker is
deterministic and visible. Every scheduled job type (email pull, queue flush,
CRM automations, reminders) still runs through Frappe's own scheduler.

The `frontend` service has a healthcheck on `/api/method/ping`, so Coolify and
Docker both report the stack as healthy. The one-shot `configurator` and
`init-site` services use `restart: "no"`, which Coolify treats as "not part of
app health" rather than a degraded service.

## Backups

`backup` runs `bench --site <SITE_NAME> backup --with-files` 15 minutes after
the stack starts and then every `BACKUP_INTERVAL_SECONDS`, keeping
`BACKUP_KEEP_DAYS` days of database + files archives under
`sites/<SITE_NAME>/private/backups/`.

Three layers, outside-in:

1. the in-stack `bench backup` above (database + public/private files);
2. the host's nightly `dump-coolify-dbs.sh` logical dump of this MariaDB
   container (patched 2026-11-04 to detect the `mariadb:11` image, whose server
   binary lives in the entrypoint, and to use `mariadb-dump`);
3. the host's nightly restic snapshot of `/var/lib/docker/volumes`, which
   contains the `sites` and `db-data` volumes of this stack.

A restore of a `bench backup` into a scratch site was performed on 2026-11-04
and matched the live site's record counts.

Restore into the same site:

```bash
docker exec -it <backend-container> bash
bench --site <SITE_NAME> --force restore \
  sites/<SITE_NAME>/private/backups/<timestamp>-database.sql.gz \
  --with-public-files sites/<SITE_NAME>/private/backups/<timestamp>-files.tar \
  --with-private-files sites/<SITE_NAME>/private/backups/<timestamp>-private-files.tar
```

## Email (two-way)

The live account is **Josh - Forefront Investors** (`josh@forefrontinvestors.com`):

| Setting | Value |
| --- | --- |
| Incoming | IMAP `imap.purelymail.com:993`, SSL, folder `INBOX`, sync ALL, initial 250 |
| Outgoing | SMTP `smtp.purelymail.com:587`, STARTTLS |
| Defaults | default outgoing **and** default incoming account |
| Sender | always the account address (`always_use_account_email_id_as_sender`) |
| Lead capture | `create_lead_from_incoming_email` = on |

Incoming mail is pulled every 10 minutes by the scheduler
(`email_account.pull`); the outbound queue is flushed every 4 minutes
(`frappe.email.queue.flush`). Replies are threaded onto the existing lead by
`In-Reply-To`/sender, and first-contact mail from an unknown sender creates a
CRM Lead with source `Email`.

### Email in the product

Frappe sends and receives through an **Email Account** (Desk → Email Account),
configured as above. The CRM-side custom field `create_lead_from_incoming_email`
turns first-contact mail into a CRM Lead.

## Operations

```bash
bench --site <SITE_NAME> migrate            # after an image bump
bench --site <SITE_NAME> clear-cache
bench --site <SITE_NAME> backup --with-files
```

Site config lives in `sites/<SITE_NAME>/site_config.json` on the `sites`
volume (inside the containers).
