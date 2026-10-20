#!/usr/bin/env bash
# Start the baseline: mock app v1.0.0 behind Nginx on http://localhost:8080
# Safe to run again: it resets everything to a clean v1.0.0.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="v1.0.0"
NETWORK="release-net"
APP_NAME="mockapp-${VERSION//./-}"   # mockapp-v1-0-0 (no dots in DNS names)
PROXY_NAME="release-proxy"
PORT=8080

echo "==> Removing containers left from earlier runs"
docker ps -aq --filter label=managed-by=release-coordinator | xargs -r docker rm -f >/dev/null

echo "==> Checking port $PORT is free"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: port $PORT is already in use:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  exit 1
fi

echo "==> Creating network $NETWORK"
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

echo "==> Building mockapp:$VERSION"
docker build --quiet --build-arg APP_VERSION="$VERSION" -t "mockapp:$VERSION" app/ >/dev/null

echo "==> Starting $APP_NAME (no host port; only the proxy is public)"
docker run -d --name "$APP_NAME" --network "$NETWORK" --restart unless-stopped \
  --label app=mockapp --label managed-by=release-coordinator --label version="$VERSION" \
  "mockapp:$VERSION" >/dev/null

echo "==> Creating $PROXY_NAME on localhost:$PORT"
docker create --name "$PROXY_NAME" --network "$NETWORK" -p "$PORT:80" --restart unless-stopped \
  --label managed-by=release-coordinator --label role=proxy \
  nginx:1.27-alpine >/dev/null

echo "==> Copying the config into the proxy and pointing it at $APP_NAME"
# No bind mounts: both files are copied into the container. Docker Desktop's file sharing
# can show a container a stale copy of a host file, and newer Docker versions reject
# `docker cp` into a container that has a file bind mount.
tmp=$(mktemp -d)
mkdir "$tmp/upstream"
echo "server ${APP_NAME}:5000;" > "$tmp/upstream/active.conf"
docker cp -q proxy/nginx.conf "$PROXY_NAME:/etc/nginx/conf.d/default.conf"
docker cp -q "$tmp/upstream" "$PROXY_NAME:/etc/nginx/upstream"
rm -rf "$tmp"

echo "==> Starting $PROXY_NAME"
# The port check above is an early warning; something can still grab the port after it.
if ! docker start "$PROXY_NAME" >/dev/null; then
  echo "ERROR: could not start $PROXY_NAME on port $PORT. Is something else using the port?" >&2
  exit 1
fi
mkdir -p state

echo "==> Saving state"
cat > state/active.json <<JSON
{"active_version": "$VERSION", "container": "$APP_NAME"}
JSON

echo "==> Waiting for http://localhost:$PORT/version"
for _ in $(seq 1 20); do
  if curl -fsS "http://localhost:$PORT/version" 2>/dev/null; then
    echo
    echo "Baseline is up."
    exit 0
  fi
  sleep 1
done
echo "ERROR: baseline did not answer within 20s. Check: docker logs $PROXY_NAME" >&2
exit 1
