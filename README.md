# Health-Gated Release Coordinator

A Python CLI that deploys a new version of a containerized app with zero downtime. It starts the
new version next to the old one and waits until it is healthy. Then it switches traffic with a
graceful Nginx reload and removes the old one. If the new version is not healthy, it removes it,
keeps traffic on the old version, and exits with a non-zero code.

```
curl localhost:8080  ->  Nginx (release-proxy)  ->  mockapp-v1-0-0  (old, keeps serving)
                                                    mockapp-v2-0-0  (new, tested first)
```

Design and reasoning: [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

Docker (running), Python 3.10+, Bash, `curl`, `lsof`, macOS or Linux, free port 8080.

## Install

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 1. Start the baseline (v1.0.0)

```bash
./bootstrap.sh
curl localhost:8080/version      # {"version":"v1.0.0"}
```

Safe to run again: it resets everything to a clean v1.0.0. Do not run `bootstrap.sh` or `teardown.sh` while a deploy is running.

## 2. Successful deploy

```bash
python deploy.py --deploy v2.0.0
curl localhost:8080/version      # {"version":"v2.0.0"}
```

## 3. Failed deploy with automatic rollback

`--fail` starts the new version with `FAIL_HEALTHCHECK=true`, so `/health` returns 500.

```bash
python deploy.py --deploy v3.0.0 --fail --timeout 10
echo $?                          # 1
curl localhost:8080/version      # still v2.0.0
```

## 4. Check for downtime (optional)

```bash
python scripts/traffic_test.py --seconds 25 &
sleep 1; python deploy.py --deploy v3.0.0; wait
```

The script sends a request every 50 ms and counts failures. In my tests: about 400 requests, 0 failed.
It is a continuity check for simple requests, not a proof for every kind of long connection.

## 5. Tests

### 5a. Automated: the main flow

```bash
./scripts/integration_test.sh
```

It takes about a minute and runs 8 checks: clean start, baseline and loopback-only port, an unrelated
container is not removed, bad options change nothing, a deploy under traffic (v1 to v2), a name conflict is
refused, a failed deploy rolls back, and teardown leaves nothing behind. Each check prints PASS or FAIL.

- It **removes your running demo**. It runs `teardown.sh` at the start and again at the end.
- It needs the `.venv` from the install steps.

### 5b. By hand: the cases the script does not cover

Use a terminal with the venv active (`source .venv/bin/activate`). The first run of a new version builds its
image, which takes a few seconds. Start from a clean baseline with v2 live:

```bash
./bootstrap.sh
python deploy.py --deploy v2.0.0
```

**1. Ctrl+C during a deploy.** Run it, and press Ctrl+C after two or three "Health check failed" lines:

```bash
python deploy.py --deploy v3.0.0 --fail --timeout 60
```

Expect: "Stopped by SIGINT before cutover" (it starts right after the `^C`, on the same line), then
"Rolling back", then "CANCELLED. Traffic stayed on v2.0.0".

Right after it, check the exit code, the running containers and the live version:

```bash
echo $?; docker ps --format '{{.Names}}'; curl localhost:8080/version
```

Expect: `1`, then only `mockapp-v2-0-0` and `release-proxy` (the new container is gone), then
`{"version":"v2.0.0"}`.

**2. `kill` (SIGTERM) during a deploy:**

```bash
python deploy.py --deploy v3.0.0 --fail --timeout 60 & sleep 5; kill -TERM $!; wait $!; echo "exit=$?"
```

Expect: "Stopped by SIGTERM before cutover", "CANCELLED", `exit=1`.

**3. `kill -9`, then run again.** `kill -9` cannot be caught, so a leftover container stays:

```bash
python deploy.py --deploy v3.0.0 --fail --timeout 60 & sleep 5; kill -9 $!; sleep 1; docker ps --format '{{.Names}}'
```

Expect: `mockapp-v3-0-0` is in the list (the leftover). Now run the same deploy again, without `--fail`:

```bash
python deploy.py --deploy v3.0.0
```

Expect: "Removing leftover container mockapp-v3-0-0", then "SUCCEEDED. v3.0.0 is live".

**4. The version is already live:**

```bash
python deploy.py --deploy v3.0.0; echo "exit=$?"
```

Expect: "v3.0.0 is already live. Nothing to do.", `exit=0`.

**5. Two deploys at once:**

```bash
python deploy.py --deploy v4.0.0 --fail --timeout 15 & sleep 3; python deploy.py --deploy v4.0.0; echo "second deploy exit=$?"; wait
```

Expect: the second one prints "Another deploy is running" and `second deploy exit=3`. The first one then ends
with "FAILED. Traffic stayed on v3.0.0".

**6. The proxy stops during the health check:**

```bash
python deploy.py --deploy v4.0.0 --passes 50 --interval 1 --timeout 60 & sleep 6; docker stop release-proxy; wait $!; echo "exit=$?"; docker start release-proxy
```

Expect: "The health check could not finish: Container ... is not running", "FAILED. v3.0.0 was not changed. If
the proxy is down, start it (docker start release-proxy)", `exit=1`. No traceback, and `v4` is removed.

**7. The proxy is stopped before the deploy:**

```bash
docker stop release-proxy; python deploy.py --deploy v4.0.0; echo "exit=$?"; docker start release-proxy
```

Expect: "Preflight failed: Proxy release-proxy is exited, not running", `exit=2`. Nothing was changed.

**8. Port 8080 is already in use:**

```bash
./teardown.sh; python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 & sleep 2; ./bootstrap.sh; echo "bootstrap exit=$?"; kill $!
```

Expect: "ERROR: port 8080 is already in use:", the line of the program that uses it (`Python`), and
`bootstrap exit=1`. Run `./bootstrap.sh` again to get the baseline back.

## 6. Clean up

```bash
./teardown.sh
```

Removes the containers labeled `managed-by=release-coordinator`, the `release-net` network, the `mockapp` images and the `state/` folder.

## Options and exit codes

| Option | Default | Meaning |
|---|---|---|
| `--deploy VERSION` | required | Version to deploy, like `v2.0.0` |
| `--timeout` | 30 | Seconds to wait for the new version to be healthy |
| `--interval` | 2 | Seconds between health checks |
| `--passes` | 3 | Health checks in a row that must pass |
| `--drain` | 5 | Seconds the old version keeps running after the switch |
| `--fail` | off | Start the new version unhealthy (demo the rollback) |

| Exit code | Meaning |
|---|---|
| 0 | Success, or the version was already live |
| 1 | Deploy failed or cancelled. New container removed. Traffic stayed on the old version. |
| 2 | Bad input, or the system is not ready. Nothing was changed. |
| 3 | Another deploy is running |
| 4 | The switch failed and the old version could not be proven public again. Both containers are kept; the log shows what to check. |

## Edge cases

| Situation | What happens |
|---|---|
| New version unhealthy, crashes, or times out | Remove it, exit 1 |
| Ctrl+C or `kill` before the switch | Remove the new container, exit 1 |
| Ctrl+C during the switch | Ignored until the switch is done (a few seconds) |
| `kill -9` in the middle | The next run removes the leftover container first |
| Two deploys at once | The second exits with 3 (`flock`) |
| Port 8080 already in use | `bootstrap.sh` stops and names the program |
| Switch not visible from outside | Switch back, check the old version is public, then remove the new container, exit 1 |
| Switch back cannot be checked | Keep both containers, print what to check, exit 4 |
| Docker or the proxy fails during the health check | Remove the new container, say what to restart, exit 1 |
| A container that is not ours | Not removed. Cleanup needs our labels (`managed-by=release-coordinator`, and `app=mockapp` for app containers). Rollback also checks the version. |

## Testing notes

The main flow runs in `scripts/integration_test.sh`. The other cases are the commands in section 5b, run by
hand, and all of them again from a fresh clone of the repo. A separate review of the repo found more problems.
All of these were found by testing and fixed:

| Problem | Fix |
|---|---|
| Nginx served a stale config: Docker Desktop showed it an old copy of a mounted file | The config lives inside the proxy container. Every switch is checked from outside (`localhost:8080/version`). |
| Another program took port 8080 between the port check and the start | `bootstrap.sh` prints a clear error and exits 1 |
| `docker cp` into a container with a file mount fails on newer Docker | No mounts. Both config files are copied in. |
| Cleanup removed any container labeled `app=mockapp`, even one that is not ours | A container must carry both of our labels |
| `--drain -1` switched traffic, then crashed | Option values are checked first, exit 2 |
| A failed switch-back could delete the live container | Prove the old version is public first. If not, keep both and exit 4. |
| The proxy port was open to the whole network | Published on 127.0.0.1 only |
| Ctrl+C during the image build could remove a container that has the same name | The name is checked before the build. Rollback removes only a container with our labels and the right version. |
| Stopping the proxy during the health check gave a traceback and left the new container running | Docker errors are caught: remove the new container, say what to restart, exit 1 |
| `--interval nan` passed the checks, then crashed | `nan` and `inf` are rejected, exit 2 |

## Limitations

One container per version, a single Nginx, no Windows support. "Healthy" means `/health` answers, which
does not prove the app is correct for users.
