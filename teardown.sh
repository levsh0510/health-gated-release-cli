#!/usr/bin/env bash
# Remove everything bootstrap.sh and deploy.py created: containers, network, images, state.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Removing containers"
docker ps -aq --filter label=managed-by=release-coordinator | xargs -r docker rm -f >/dev/null

echo "==> Removing network release-net"
docker network rm release-net >/dev/null 2>&1 || true

echo "==> Removing images mockapp:*"
docker images mockapp -q | sort -u | xargs -r docker rmi -f >/dev/null

echo "==> Removing state"
rm -rf state

echo "Clean."
