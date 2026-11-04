#!/usr/bin/env bash
# Gate for the Frappe CRM Coolify stack.
#
# Runs on a fresh checkout with no dependencies beyond bash + coreutils, and
# adds `docker compose config` validation when a Docker CLI is available (the
# VPS has one; the CI runner may not). Never touches production.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

COMPOSE=docker-compose.yaml
[ -f "$COMPOSE" ] || fail "$COMPOSE missing"

# --- 1. required services -------------------------------------------------
for svc in db redis-cache redis-queue configurator init-site backend frontend \
           websocket queue-short queue-long scheduler backup; do
  grep -qE "^  ${svc}:$" "$COMPOSE" || fail "service '$svc' missing from $COMPOSE"
done
ok "all expected services present"

# --- 2. the image is pinned to a release, never a floating tag ------------
grep -q 'image: ${CUSTOM_IMAGE:-frappe-crm}:${CUSTOM_TAG:-[0-9][0-9.]*}' "$COMPOSE" \
  || fail "frappe image must be pinned via CUSTOM_TAG default of an X.Y.Z release"
grep -qE 'CUSTOM_TAG:-(latest|stable|develop|main|nightly)' "$COMPOSE" \
  && fail "CUSTOM_TAG must not default to a floating tag"
grep -q 'pull_policy: ${PULL_POLICY:-never}' "$COMPOSE" \
  || fail "the locally built image must not be pulled"
[ -x scripts/build-image.sh ] || fail "scripts/build-image.sh must exist and document the image build"
grep -q 'v1\.92\.0' scripts/build-image.sh || fail "build-image.sh must pin the crm release"
ok "image pinned to a release tag, built locally"

# --- 3. no host port publishing, no hand-written proxy labels -------------
grep -qE '^[[:space:]]+ports:' "$COMPOSE" && fail "no service may publish a host port; Coolify routes internally"
grep -qE 'traefik\.|caddy_' "$COMPOSE" && fail "proxy labels belong to Coolify, not this file"
grep -qE 'container_name:' "$COMPOSE" && fail "container_name breaks Coolify redeploys"
ok "no host ports, no proxy labels, no container_name"

# --- 4. frontend is the only routed service, on 8080 ----------------------
awk '/^  frontend:/{f=1} f&&/^  [a-z-]+:/&&!/^  frontend:/{exit} f' "$COMPOSE" \
  | grep -q '"8080"' || fail "frontend must expose 8080"
[ "$(grep -cE '^[[:space:]]+expose:' "$COMPOSE")" -eq 1 ] || fail "only frontend should expose a port"
ok "frontend exposes 8080, nothing else does"

# --- 5. persistent storage declared --------------------------------------
for vol in sites db-data redis-queue-data; do
  grep -qE "^  ${vol}:$" "$COMPOSE" || fail "volume '$vol' not declared"
done
grep -q 'sites:/home/frappe/frappe-bench/sites' "$COMPOSE" || fail "sites volume not mounted"
ok "persistent volumes declared"

# --- 6. backups are image-local (no docker socket) -----------------------
grep -q 'backup --with-files' "$COMPOSE" || fail "backup service must run bench backup --with-files"
grep -q '/var/run/docker.sock' "$COMPOSE" && fail "backup must not mount the docker socket"
ok "in-stack backups, no docker socket"

# --- 7. no credentials committed -----------------------------------------
if grep -nEi 'password[[:space:]]*:[[:space:]]*[^$"[:space:]]{6,}' "$COMPOSE" \
     | grep -vE 'DB_PASSWORD|ADMIN_PASSWORD|password: "?\\$' ; then
  fail "literal credential found in $COMPOSE"
fi
for f in .env .env.local .secrets; do
  [ -e "$f" ] && fail "$f must never be committed"
done
ok "no secrets in the tree"

# --- 8. optional: compose actually renders -------------------------------
TMPENV=$(mktemp)
trap 'rm -f "$TMPENV"' EXIT
cat > "$TMPENV" <<'ENV'
DB_PASSWORD=verify-only
SITE_NAME=verify.example.com
ADMIN_PASSWORD=verify-only-admin
ENV
if command -v docker >/dev/null 2>&1; then
  docker compose -f "$COMPOSE" --env-file "$TMPENV" config -q >/dev/null \
    || fail "docker compose config rejected $COMPOSE"
  ok "docker compose config renders"
else
  echo "skip: docker CLI not available, compose render not checked"
fi

echo "verify: PASS"
