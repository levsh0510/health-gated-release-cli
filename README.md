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

## 5. Clean up

```bash
./teardown.sh
```

Removes the containers, the `release-net` network, the `mockapp` images and the `state/` folder.

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
| A container that is not ours | Never removed. Only containers with both our labels are touched. |

## Testing notes

All cases above were run by hand. Two real problems showed up and were fixed:

- **Stale Nginx config.** The upstream file was mounted from my Mac, and Docker Desktop showed Nginx an old
  copy. Fix: the file now lives inside the proxy container, and every switch is checked from outside
  (`localhost:8080/version` must return the new version).
- **Port race.** Another program took port 8080 between the check and the start. Docker refused the port.
  Fix: `bootstrap.sh` now prints a clear error and exits 1.

## Limitations

One container per version, a single Nginx, no Windows support. "Healthy" means `/health` answers, which
does not prove the app is correct for users.
