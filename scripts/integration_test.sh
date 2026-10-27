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
FINISHED=0

# Colors only when printing to a terminal (set NO_COLOR=1 to turn them off).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  CYAN=$'\033[36m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; CYAN=""; BLUE=""; RESET=""
fi

# Layout of the output:
#   TEST header + Purpose       what is being proved
#   $ command                   the command that runs (bold, cyan)
#       | output                what the command printed (dim, indented)
#   ✓ check: ...               what was compared and that it matched (green)
fail() {
  echo
  echo "${RED}${BOLD}FAIL: $*${RESET}" >&2
  exit 1
}

step() {
  CURRENT_STEP="$1"
  echo
  echo "${BOLD}${BLUE}================================================================${RESET}"
  echo "${BOLD}${BLUE}TEST $1/$TOTAL_TESTS: $2${RESET}"
  echo "${BOLD}Purpose:${RESET} $3"
}

pass_step() {
  PASSED_TESTS=$((PASSED_TESTS + 1))
  echo
  echo "${GREEN}${BOLD}PASS [$CURRENT_STEP/$TOTAL_TESTS]: $1${RESET}"
  echo "${GREEN}Result: $2${RESET}"
}

# Indent everything a command prints, so it is easy to tell apart from our own lines.
indent() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s      | %s%s\n' "$DIM" "$line" "$RESET"
  done
}

# Print a command the way you would type it ($PYTHON is shown as plain "python").
# Arguments with special characters are quoted, so the line can be copied and run.
show() {
  local line="" arg
  for arg in "$@"; do
    [[ "$arg" == "$PYTHON" ]] && arg="python"
    if [[ "$arg" =~ [^A-Za-z0-9_./:=@%+,-] ]]; then
      arg="'$arg'"
    fi
    line+="$arg "
  done
  printf '\n%s  $ %s%s\n' "${BOLD}${CYAN}" "${line% }" "$RESET"
}

# Print a text line as a command (used where the command has a pipe, a redirect or a comment).
say() {
  printf '\n%s  $ %s%s\n' "${BOLD}${CYAN}" "$*" "$RESET"
}

# Print a check that passed.
check() {
  printf '%s  ✓ check: %s%s\n' "$GREEN" "$*" "$RESET"
}

# Print a command, run it, and show its output indented.
run() {
  show "$@"
  "$@" 2>&1 | indent || fail "command failed: $*"
}

# capture <variable> <command...>: print the command, run it, show and keep its output.
capture() {
  local _var="$1"
  shift
  local _output
  show "$@"
  _output="$("$@")" || fail "command failed: $*"
  [[ -z "$_output" ]] || printf '%s\n' "$_output" | indent
  printf -v "$_var" '%s' "$_output"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
  check "$message: '$actual' (as expected)"
}

assert_absent() {
  local container="$1"
  local matches
  say "docker ps -a --filter 'name=^/${container}\$' --format '{{.Names}}'"
  matches="$(docker ps -a --filter "name=^/${container}$" --format '{{.Names}}')" \
    || fail "could not query Docker for $container"
  if [[ -n "$matches" ]]; then
    fail "container $container should not exist"
  fi
  check "container $container does not exist (the list above is empty)"
}

# expect_exit <code> <command...>: print the command, run it, and check its exit code.
expect_exit() {
  local expected="$1"
  shift
  show "$@"
  set +e
  "$@" 2>&1 | indent
  local actual="${PIPESTATUS[0]}"
  set -e
  [[ "$actual" -eq "$expected" ]] || fail "expected exit $expected, got $actual: $*"
  check "exit code is $actual (as expected)"
}

cleanup() {
  local status=$?
  trap - EXIT
  # macOS bash reports status 0 after an "unbound variable" crash, so check that we reached the end
  if [[ "$status" -eq 0 && "$FINISHED" -ne 1 ]]; then
    status=1
  fi
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

echo "${BOLD}================================================================${RESET}"
echo "${BOLD}Health-Gated Release Coordinator — Full Integration Test${RESET}"
echo "Repository: $ROOT"
echo "Checks: baseline, routing, validation, cutover, ownership,"
echo "        rollback, and cleanup"
echo "${BOLD}================================================================${RESET}"

step 1 "Clean starting environment" \
  "Remove prior assessment resources so results are reproducible."
run ./teardown.sh
pass_step "Clean start" "Previous assessment containers, network, images, and state were removed."

step 2 "Bootstrap and baseline health" \
  "Start v1, verify both public endpoints, and confirm loopback-only exposure."
run ./bootstrap.sh
capture out curl -fsS http://localhost:8080/version
assert_eq '{"version":"v1.0.0"}' "$out" "baseline version"
capture out curl -fsS http://localhost:8080/health
assert_eq '{"status":"ok","version":"v1.0.0"}' "$out" "baseline health"
capture out docker port release-proxy 80/tcp
assert_eq '127.0.0.1:8080' "$out" "proxy binding"
pass_step "Baseline is healthy" "Version v1.0.0 and health OK are public only on 127.0.0.1:8080."

step 3 "Ownership-safe reconciliation" \
  "Prove deployment cleanup does not remove an unrelated app=mockapp container."
say "docker run -d --name $UNRELATED_NAME --label app=mockapp nginx:1.27-alpine sh -c 'sleep 300'"
UNRELATED_ID="$(docker run -d --name "$UNRELATED_NAME" --label app=mockapp \
  nginx:1.27-alpine sh -c 'sleep 300')"
run "$PYTHON" deploy.py --deploy v1.0.0
capture unrelated_status docker inspect --format '{{.State.Status}}' "$UNRELATED_NAME"
assert_eq 'running' "$unrelated_status" \
  "unrelated container status"
say "docker rm -f $UNRELATED_NAME"
docker rm -f "$UNRELATED_ID" >/dev/null
UNRELATED_ID=""
pass_step "Unrelated container was preserved" "The foreign app-label-only container stayed running."

step 4 "Input validation before mutation" \
  "Reject unsafe values without changing images, state, routing, or containers."
capture state_before cat state/active.json
capture upstream_before docker exec release-proxy cat /etc/nginx/upstream/active.conf
expect_exit 2 "$PYTHON" deploy.py --deploy v4.0.0 --interval nan
expect_exit 2 "$PYTHON" deploy.py --deploy v4.0.0 --drain -1
assert_absent mockapp-v4-0-0
capture v4_images docker images mockapp:v4.0.0 -q
assert_eq '' "$v4_images" "no mockapp:v4.0.0 image was built"
capture state_after cat state/active.json
capture upstream_after docker exec release-proxy cat /etc/nginx/upstream/active.conf
assert_eq "$state_before" "$state_after" "state after invalid input"
assert_eq "$upstream_before" "$upstream_after" "upstream after invalid input"
capture out curl -fsS http://localhost:8080/version
assert_eq '{"version":"v1.0.0"}' "$out" "version after invalid input"
pass_step "Invalid input caused no mutation" "NaN and negative drain exited 2; v1 routing and state were unchanged."

step 5 "Healthy cutover with request continuity" \
  "Deploy v2 with the default health gate while continuously requesting /version."
TRAFFIC_LOG="$(mktemp "${TMPDIR:-/tmp}/release-traffic.XXXXXX")"
say "python scripts/traffic_test.py --seconds 25 &     # runs in the background; its summary is printed below"
"$PYTHON" scripts/traffic_test.py --seconds 25 >"$TRAFFIC_LOG" 2>&1 &
TRAFFIC_PID=$!
run "$PYTHON" deploy.py --deploy v2.0.0
say "wait     # for the traffic test to finish, then show what it counted"
set +e
wait "$TRAFFIC_PID"
traffic_status=$?
set -e
TRAFFIC_PID=""
indent < "$TRAFFIC_LOG"
[[ "$traffic_status" -eq 0 ]] || fail "traffic continuity check exited $traffic_status"
check "traffic test exit code is $traffic_status (as expected)"
grep -Eq '^traffic: [1-9][0-9]* requests, 0 failed$' "$TRAFFIC_LOG" \
  || fail "traffic summary did not report zero failures"
grep -Eq '^  v1\.0\.0: [1-9][0-9]*$' "$TRAFFIC_LOG" \
  || fail "traffic did not observe v1"
grep -Eq '^  v2\.0\.0: [1-9][0-9]*$' "$TRAFFIC_LOG" \
  || fail "traffic did not observe v2"
check "0 failed requests, and both v1 and v2 answered"
traffic_summary="$(grep -E '^traffic:' "$TRAFFIC_LOG")"
rm -f "$TRAFFIC_LOG"
TRAFFIC_LOG=""
capture out curl -fsS http://localhost:8080/version
assert_eq '{"version":"v2.0.0"}' "$out" "version after successful deployment"
capture managed_apps docker ps -a --filter label=app=mockapp --filter label=managed-by=release-coordinator --format '{{.Names}}'
assert_eq 'mockapp-v2-0-0' "$managed_apps" \
  "remaining managed app"
pass_step "Traffic switched from v1 to v2" "$traffic_summary; both versions observed; only v2 remains."

step 6 "Same-name foreign-container protection" \
  "Refuse deployment rather than deleting a container not created by this run."
say "docker run -d --name $FOREIGN_NAME --label managed-by=release-coordinator nginx:1.27-alpine sh -c 'sleep 300'"
FOREIGN_ID="$(docker run -d --name "$FOREIGN_NAME" --label managed-by=release-coordinator \
  nginx:1.27-alpine sh -c 'sleep 300')"
expect_exit 2 "$PYTHON" deploy.py --deploy "$FOREIGN_VERSION"
capture foreign_status docker inspect --format '{{.State.Status}}' "$FOREIGN_NAME"
assert_eq 'running' "$foreign_status" \
  "same-name foreign container status"
say "docker rm -f $FOREIGN_NAME"
docker rm -f "$FOREIGN_ID" >/dev/null
FOREIGN_ID=""
pass_step "Foreign container was preserved" "Deployment exited 2 and the same-name container stayed running."

step 7 "Automatic failed-health rollback" \
  "Force v3 health checks to fail and verify stable v2 remains public."
expect_exit 1 "$PYTHON" deploy.py --deploy v3.0.0 --fail --timeout 10
capture out curl -fsS http://localhost:8080/version
assert_eq '{"version":"v2.0.0"}' "$out" "version after failed deployment"
assert_absent mockapp-v3-0-0
pass_step "Unhealthy v3 was rolled back" "Candidate removed; stable v2.0.0 remained public."

step 8 "Final teardown verification" \
  "Remove the assessment stack and prove no managed resources or local state remain."
run ./teardown.sh
capture managed_containers docker ps -aq --filter label=managed-by=release-coordinator
assert_eq '' "$managed_containers" "no managed containers remain"
capture release_network docker network ls --filter 'name=^release-net$' --format '{{.Name}}'
assert_eq '' "$release_network" "release-net network is gone"
capture mockapp_images docker images mockapp -q
assert_eq '' "$mockapp_images" "no mockapp images remain"
say "test ! -e state"
[[ ! -e state ]] || fail "state directory remains"
check "the state/ folder does not exist"
pass_step "Environment is clean" "No managed containers, release network, mockapp images, or state remain."

FINISHED=1
echo
echo "${GREEN}${BOLD}================================================================${RESET}"
echo "${GREEN}${BOLD}RESULT: $PASSED_TESTS/$TOTAL_TESTS feature checks passed${RESET}"
echo "${GREEN}${BOLD}STATUS: SUCCESS${RESET}"
echo "RUNTIME: $((SECONDS - START_SECONDS)) seconds"
echo "The full integration workflow completed and left the environment clean."
echo "${GREEN}${BOLD}================================================================${RESET}"
