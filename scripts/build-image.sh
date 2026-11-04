#!/usr/bin/env bash
# Build the image this stack runs: Frappe Framework v16 + frappe/crm v1.92.0
# (+ frappe/flow for the in-site AI assistant).
#
# Why we build instead of pulling ghcr.io/frappe/crm: that image ships without
# the crm app (its release workflow passes APPS_JSON_BASE64 as a build argument,
# but the Containerfile now reads apps.json through a BuildKit secret mount), and
# it is built on Frappe v15, which has no MCP server. Verified 2026-11-04:
#   docker run --rm --entrypoint bash ghcr.io/frappe/crm:v1.92.0 -c 'ls apps'
#   -> frappe
#
# Run this on the Coolify host, before the first deploy and after any version
# bump. Requires the docker buildx plugin (>= v0.30).
set -euo pipefail

FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-16}
CRM_BRANCH=${CRM_BRANCH:-v1.92.0}
FLOW_BRANCH=${FLOW_BRANCH:-develop}   # set to "" to build without Flow
IMAGE=${IMAGE:-frappe-crm}
TAG=${TAG:-1.92.0-v16}
WORKDIR=${WORKDIR:-/opt/frappe-crm-build}

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx plugin required" >&2; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d frappe_docker/.git ]; then
  git clone --depth 1 https://github.com/frappe/frappe_docker.git
fi

python3 - "$WORKDIR/apps.json" "$CRM_BRANCH" "$FLOW_BRANCH" <<'PY'
import json, sys
path, crm_branch, flow_branch = sys.argv[1], sys.argv[2], sys.argv[3]
apps = [{"url": "https://github.com/frappe/crm", "branch": crm_branch}]
if flow_branch:
    apps.append({"url": "https://github.com/frappe/flow_client", "branch": flow_branch})
json.dump(apps, open(path, "w"))
PY

cd frappe_docker
docker buildx build \
  --build-arg "FRAPPE_BRANCH=$FRAPPE_BRANCH" \
  --secret "id=apps_json,src=$WORKDIR/apps.json" \
  --load \
  -f images/layered/Containerfile \
  -t "$IMAGE:$TAG" \
  .

docker run --rm --entrypoint bash "$IMAGE:$TAG" -c 'ls apps'
echo "built $IMAGE:$TAG"
