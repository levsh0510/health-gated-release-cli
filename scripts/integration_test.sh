#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [repository-path]" >&2
  exit 2
fi
if [[ "$#" -eq 1 ]]; then
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

PYTHON="$ROOT/.venv/bin/python"
RUN_ID="$$"
UNRELATED_NAME="release-test-unrelated-$RUN_ID"
FOREIGN_VERSION="v4.0.$RUN_ID"
FOREIGN_NAME="mockapp-v4-0-$RUN_ID"
UNRELATED_ID=""
FOREIGN_ID=""
TRAFFIC_PID=""
TRAFFIC_LOG=""
TOTAL_TESTS=8
PASSED_TESTS=0
CURRENT_STEP=0
START_SECONDS=$SECONDS

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() {
  CURRENT_STEP="$1"
  echo
  echo "----------------------------------------------------------------"
  echo "TEST $1/$TOTAL_TESTS: $2"
  echo "Purpose: $3"
}

pass_step() {
  PASSED_TESTS=$((PASSED_TESTS + 1))
  echo "PASS [$CURRENT_STEP/$TOTAL_TESTS]: $1"
  echo "Result: $2"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_absent() {
  local container="$1"
  local matches
  matches="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}')" \
    || fail "could not query Docker for $container"
  if [[ -n "$matches" ]]; then
    fail "container $container should not exist"
  fi
}

expect_exit() {
  local expected="$1"
  shift
  set +e
  "$@"
  local actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || fail "expected exit $expected, got $actual: $*"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$TRAFFIC_PID" ]] && kill -0 "$TRAFFIC_PID" >/dev/null 2>&1; then
    kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
    wait "$TRAFFIC_PID" >/dev/null 2>&1 || true
  fi
  [[ -z "$UNRELATED_ID" ]] || docker rm -f "$UNRELATED_ID" >/dev/null 2>&1 || true
  [[ -z "$FOREIGN_ID" ]] || docker rm -f "$FOREIGN_ID" >/dev/null 2>&1 || true
  [[ -z "$TRAFFIC_LOG" ]] || rm -f "$TRAFFIC_LOG" || true
  "$ROOT/teardown.sh" >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

cd "$ROOT"

[[ -f deploy.py && -x bootstrap.sh && -x teardown.sh ]] \
  || fail "$ROOT is not the health-gated release repository"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
[[ -x "$PYTHON" ]] || fail "missing $PYTHON; follow the README install steps first"
docker info >/dev/null 2>&1 || fail "Docker is not reachable"

echo "================================================================"
echo "Health-Gated Release Coordinator — Full Integration Test"
echo "Repository: $ROOT"
echo "Checks: baseline, routing, validation, cutover, ownership,"
echo "        rollback, and cleanup"
echo "================================================================"

step 1 "Clean starting environment" \
  "Remove prior assessment resources so results are reproducible."
./teardown.sh
pass_step "Clean start" "Previous assessment containers, network, images, and state were removed."

step 2 "Bootstrap and baseline health" \
  "Start v1, verify both public endpoints, and confirm loopback-only exposure."
./bootstrap.sh
assert_eq '{"version":"v1.0.0"}' "$(curl -fsS http://localhost:8080/version)" \
  "baseline version"
assert_eq '{"status":"ok","version":"v1.0.0"}' "$(curl -fsS http://localhost:8080/health)" \
  "baseline health"
assert_eq '127.0.0.1:8080' "$(docker port release-proxy 80/tcp)" \
  "proxy binding"
pass_step "Baseline is healthy" "Version v1.0.0 and health OK are public only on 127.0.0.1:8080."

step 3 "Ownership-safe reconciliation" \
  "Prove deployment cleanup does not remove an unrelated app=mockapp container."
UNRELATED_ID="$(docker run -d --name "$UNRELATED_NAME" --label app=mockapp \
  nginx:1.27-alpine sh -c 'sleep 300')"
"$PYTHON" deploy.py --deploy v1.0.0
unrelated_status="$(docker inspect --format '{{.State.Status}}' "$UNRELATED_ID")" \
  || fail "could not inspect unrelated fixture $UNRELATED_ID"
assert_eq 'running' "$unrelated_status" \
  "unrelated container status"
docker rm -f "$UNRELATED_ID" >/dev/null
UNRELATED_ID=""
pass_step "Unrelated container was preserved" "The foreign app-label-only container stayed running."

step 4 "Input validation before mutation" \
  "Reject unsafe values without changing images, state, routing, or containers."
state_before="$(cat state/active.json)" || fail "could not read state before invalid-input checks"
upstream_before="$(docker exec release-proxy cat /etc/nginx/upstream/active.conf)" \
  || fail "could not read upstream before invalid-input checks"
expect_exit 2 "$PYTHON" deploy.py --deploy v4.0.0 --interval nan
expect_exit 2 "$PYTHON" deploy.py --deploy v4.0.0 --drain -1
assert_absent mockapp-v4-0-0
v4_images="$(docker images mockapp:v4.0.0 -q)" || fail "could not query v4 images"
[[ -z "$v4_images" ]] || fail "invalid input created mockapp:v4.0.0"
state_after="$(cat state/active.json)" || fail "could not read state after invalid-input checks"
upstream_after="$(docker exec release-proxy cat /etc/nginx/upstream/active.conf)" \
  || fail "could not read upstream after invalid-input checks"
assert_eq "$state_before" "$state_after" "state after invalid input"
assert_eq "$upstream_before" "$upstream_after" "upstream after invalid input"
assert_eq '{"version":"v1.0.0"}' "$(curl -fsS http://localhost:8080/version)" \
  "version after invalid input"
pass_step "Invalid input caused no mutation" "NaN and negative drain exited 2; v1 routing and state were unchanged."

step 5 "Healthy cutover with request continuity" \
  "Deploy v2 with the default health gate while continuously requesting /version."
TRAFFIC_LOG="$(mktemp "${TMPDIR:-/tmp}/release-traffic.XXXXXX")"
"$PYTHON" scripts/traffic_test.py --seconds 25 >"$TRAFFIC_LOG" 2>&1 &
TRAFFIC_PID=$!
"$PYTHON" deploy.py --deploy v2.0.0
set +e
wait "$TRAFFIC_PID"
traffic_status=$?
set -e
TRAFFIC_PID=""
cat "$TRAFFIC_LOG"
[[ "$traffic_status" -eq 0 ]] || fail "traffic continuity check exited $traffic_status"
grep -Eq '^traffic: [1-9][0-9]* requests, 0 failed$' "$TRAFFIC_LOG" \
  || fail "traffic summary did not report zero failures"
grep -Eq '^  v1\.0\.0: [1-9][0-9]*$' "$TRAFFIC_LOG" \
  || fail "traffic did not observe v1"
grep -Eq '^  v2\.0\.0: [1-9][0-9]*$' "$TRAFFIC_LOG" \
  || fail "traffic did not observe v2"
traffic_summary="$(grep -E '^traffic:' "$TRAFFIC_LOG")"
rm -f "$TRAFFIC_LOG"
TRAFFIC_LOG=""
assert_eq '{"version":"v2.0.0"}' "$(curl -fsS http://localhost:8080/version)" \
  "version after successful deployment"
managed_apps="$(docker ps -a --filter label=app=mockapp \
  --filter label=managed-by=release-coordinator --format '{{.Names}}')" \
  || fail "could not query managed apps"
assert_eq 'mockapp-v2-0-0' "$managed_apps" \
  "remaining managed app"
pass_step "Traffic switched from v1 to v2" "$traffic_summary; both versions observed; only v2 remains."

step 6 "Same-name foreign-container protection" \
  "Refuse deployment rather than deleting a container not created by this run."
FOREIGN_ID="$(docker run -d --name "$FOREIGN_NAME" --label managed-by=release-coordinator \
  nginx:1.27-alpine sh -c 'sleep 300')"
expect_exit 2 "$PYTHON" deploy.py --deploy "$FOREIGN_VERSION"
foreign_status="$(docker inspect --format '{{.State.Status}}' "$FOREIGN_ID")" \
  || fail "could not inspect foreign fixture $FOREIGN_ID"
assert_eq 'running' "$foreign_status" \
  "same-name foreign container status"
docker rm -f "$FOREIGN_ID" >/dev/null
FOREIGN_ID=""
pass_step "Foreign container was preserved" "Deployment exited 2 and the same-name container stayed running."

step 7 "Automatic failed-health rollback" \
  "Force v3 health checks to fail and verify stable v2 remains public."
expect_exit 1 "$PYTHON" deploy.py --deploy v3.0.0 --fail --timeout 10
assert_eq '{"version":"v2.0.0"}' "$(curl -fsS http://localhost:8080/version)" \
  "version after failed deployment"
assert_absent mockapp-v3-0-0
pass_step "Unhealthy v3 was rolled back" "Candidate removed; stable v2.0.0 remained public."

step 8 "Final teardown verification" \
  "Remove the assessment stack and prove no managed resources or local state remain."
./teardown.sh
managed_containers="$(docker ps -aq --filter label=managed-by=release-coordinator)" \
  || fail "could not query managed containers"
[[ -z "$managed_containers" ]] || fail "managed containers remain"
release_network="$(docker network ls --filter name='^release-net$' --format '{{.Name}}')" \
  || fail "could not query release-net"
[[ -z "$release_network" ]] || fail "release-net remains"
mockapp_images="$(docker images mockapp -q)" || fail "could not query mockapp images"
[[ -z "$mockapp_images" ]] || fail "mockapp images remain"
[[ ! -e state ]] || fail "state directory remains"
pass_step "Environment is clean" "No managed containers, release network, mockapp images, or state remain."

echo
echo "================================================================"
echo "RESULT: $PASSED_TESTS/$TOTAL_TESTS feature checks passed"
echo "STATUS: SUCCESS"
echo "RUNTIME: $((SECONDS - START_SECONDS)) seconds"
echo "The full integration workflow completed and left the environment clean."
echo "================================================================"
