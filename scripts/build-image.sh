#!/usr/bin/env bash
# Build the image this stack runs: Frappe Framework v15 + frappe/crm v1.92.0.
#
# Why we build instead of pulling ghcr.io/frappe/crm:v1.92.0: that image is
# missing the crm app. The release workflow passes APPS_JSON_BASE64 as a build
# argument, but images/layered/Containerfile now reads apps.json through a
# BuildKit secret mount, so the argument is silently ignored and the published
# image contains only the framework. Verified 2026-11-04 on the Coolify host:
#   docker run --rm --entrypoint bash ghcr.io/frappe/crm:v1.92.0 -c 'ls apps'
#   -> frappe
#
# Run this on the Coolify host, once, before the first deploy and after any
# version bump. Requires the docker buildx plugin (>= v0.30).
set -euo pipefail

FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-15}
CRM_BRANCH=${CRM_BRANCH:-v1.92.0}
IMAGE=${IMAGE:-frappe-crm}
TAG=${TAG:-1.92.0}
WORKDIR=${WORKDIR:-/opt/frappe-crm-build}

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx plugin required" >&2; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -d frappe_docker/.git ]; then
  git clone --depth 1 https://github.com/frappe/frappe_docker.git
fi

python3 - "$WORKDIR/apps.json" "$CRM_BRANCH" <<'PY'
import json, sys
path, branch = sys.argv[1], sys.argv[2]
json.dump([{"url": "https://github.com/frappe/crm", "branch": branch}], open(path, "w"))
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
