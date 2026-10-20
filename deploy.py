#!/usr/bin/env python3
"""Health-gated release: deploy a new mockapp version behind Nginx with zero downtime.

Usage:  python deploy.py --deploy v2.0.0
"""
import argparse
import fcntl
import json
import logging
import os
import re
import signal
import sys
import time
from contextlib import contextmanager
from pathlib import Path

import docker
import requests
from docker.errors import APIError, DockerException, NotFound

# Names shared with bootstrap.sh
ROOT = Path(__file__).resolve().parent
NETWORK = "release-net"
PROXY = "release-proxy"
APP_PORT = 5000
UPSTREAM_FILE = "/etc/nginx/upstream/active.conf"  # inside the proxy container
PUBLIC_URL = "http://localhost:8080"
STATE_FILE = ROOT / "state" / "active.json"
LOCK_FILE = ROOT / "state" / "deploy.lock"
LABELS = {"app": "mockapp", "managed-by": "release-coordinator"}
OURS = [f"{k}={v}" for k, v in LABELS.items()]  # a container must carry both labels to be ours

# Exit codes
EXIT_OK = 0
EXIT_ROLLED_BACK = 1
EXIT_BAD_INPUT = 2
EXIT_LOCKED = 3

log = logging.getLogger("deploy")


# ══════════════════════════════════════════════════════════════════
# Errors and Ctrl+C handling (used in Steps 3–7)
# ══════════════════════════════════════════════════════════════════

class DeployError(Exception):
    """A problem we can explain to the user in one line."""


class Interrupted(Exception):
    """Ctrl+C (SIGINT) or SIGTERM arrived."""


_in_cutover = False


def on_signal(signum, frame):
    name = signal.Signals(signum).name
    if _in_cutover:
        log.warning("Got %s during cutover. Finishing the cutover first (it takes a few seconds).", name)
        return
    raise Interrupted(name)


@contextmanager
def no_interrupts():
    """Signals inside this block are logged and ignored, so the cutover never stops halfway."""
    global _in_cutover
    _in_cutover = True
    try:
        yield
    finally:
        _in_cutover = False


# ══════════════════════════════════════════════════════════════════
# Step 1: read the options
# ══════════════════════════════════════════════════════════════════

def container_name(version):
    """v2.0.0 -> mockapp-v2-0-0 (no dots in DNS names)."""
    return "mockapp-" + version.replace(".", "-")


def version_arg(value):
    if not re.fullmatch(r"v\d+\.\d+\.\d+", value):
        raise argparse.ArgumentTypeError(f"'{value}' is not a version like v2.0.0")
    return value


def number(kind, minimum, strict):
    """An argparse type: a number of `kind`, above `minimum` (strict) or at least `minimum`."""
    def parse(value):
        try:
            n = kind(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"'{value}' is not a number")
        if n < minimum or (strict and n == minimum):
            raise argparse.ArgumentTypeError(f"must be {'greater than' if strict else 'at least'} {minimum}")
        return n
    return parse


def parse_args():
    p = argparse.ArgumentParser(description="Deploy a new mockapp version with a health gate.")
    p.add_argument("--deploy", required=True, type=version_arg, metavar="VERSION",
                   help="version to deploy, e.g. v2.0.0")
    p.add_argument("--timeout", type=number(int, 0, strict=True), default=30,
                   help="seconds to wait for the new version to become healthy (default 30)")
    p.add_argument("--interval", type=number(float, 0, strict=True), default=2,
                   help="seconds between health checks (default 2)")
    p.add_argument("--passes", type=number(int, 1, strict=False), default=3,
                   help="health checks in a row that must pass (default 3)")
    p.add_argument("--drain", type=number(int, 0, strict=False), default=5,
                   help="seconds to keep the old version after cutover (default 5)")
    p.add_argument("--fail", action="store_true",
                   help="start the new version with FAIL_HEALTHCHECK=true (demo the rollback)")
    return p.parse_args()


# ══════════════════════════════════════════════════════════════════
# Step 2: the lock, and the state file (state is saved in Step 6)
# ══════════════════════════════════════════════════════════════════

def acquire_lock():
    """Only one deploy at a time. The OS releases the lock if this process dies, even on kill -9."""
    LOCK_FILE.parent.mkdir(exist_ok=True)
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return None
    return lock  # keep this object alive; closing it releases the lock


def read_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_state(version):
    """Write to a temp file, then rename. A crash leaves the old file or the new one, never half of one."""
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"active_version": version, "container": container_name(version)}) + "\n")
    os.replace(tmp, STATE_FILE)


# ══════════════════════════════════════════════════════════════════
# Step 3: check the system, clean up leftovers
# ══════════════════════════════════════════════════════════════════

def preflight():
    """Check everything bootstrap.sh set up is still there. Change nothing."""
    try:
        client = docker.from_env()
        client.ping()
    except DockerException as e:
        raise DeployError(f"Docker is not reachable. Is Docker Desktop running? ({e})")
    try:
        client.networks.get(NETWORK)
        proxy = client.containers.get(PROXY)
    except NotFound as e:
        raise DeployError(f"{e.explanation}. Run ./bootstrap.sh first.")
    if proxy.status != "running":
        raise DeployError(f"Proxy {PROXY} is {proxy.status}, not running. Run ./bootstrap.sh first.")
    return client


def proxy_exec(client, cmd):
    """Run a command inside the proxy container. Returns (exit_code, output)."""
    result = client.containers.get(PROXY).exec_run(cmd)
    return result.exit_code, result.output.decode(errors="replace").strip()


def reload_proxy(client):
    """Test the config first; a bad config must never reach Nginx. Reload is graceful."""
    code, out = proxy_exec(client, "nginx -t")
    if code != 0:
        raise DeployError(f"nginx config test failed: {out}")
    code, out = proxy_exec(client, "nginx -s reload")
    if code != 0:
        raise DeployError(f"nginx reload failed: {out}")


def read_upstream(client):
    """Which container Nginx sends traffic to, from 'server mockapp-v1-0-0:5000;'."""
    code, out = proxy_exec(client, f"cat {UPSTREAM_FILE}")
    match = re.search(r"server\s+([\w.-]+):\d+;", out) if code == 0 else None
    if not match:
        raise DeployError(f"Can't read {UPSTREAM_FILE} in {PROXY}. Run ./bootstrap.sh to reset.")
    return match.group(1)


def reconcile(client):
    """Clean up after a run that crashed. The upstream file is the truth: it is where traffic goes.

    Returns the live version.
    """
    live_name = read_upstream(client)
    try:
        live = client.containers.get(live_name)
    except NotFound:
        raise DeployError(f"Proxy points at {live_name}, but that container does not exist. "
                          "Run ./bootstrap.sh to reset.")
    if live.status != "running":
        raise DeployError(f"Live container {live_name} is {live.status}. Run ./bootstrap.sh to reset.")

    # If an earlier run died after writing the file but before the reload, finish the reload now.
    reload_proxy(client)

    for c in client.containers.list(all=True, filters={"label": OURS}):
        if c.name != live_name:
            log.warning("Removing leftover container %s (from a run that did not finish)", c.name)
            c.remove(force=True)

    version = live.labels["version"]
    state = read_state()
    if not state or state.get("container") != live_name:
        log.warning("State file was out of date; fixing it to %s", version)
        write_state(version)
    return version


# ══════════════════════════════════════════════════════════════════
# Step 5: start the new version and test it
# ══════════════════════════════════════════════════════════════════

def ensure_image(client, version):
    """Build mockapp:<version> if missing. In real life CI builds it and we pull it from a registry."""
    tag = f"mockapp:{version}"
    try:
        client.images.get(tag)
        log.info("Image %s already exists", tag)
    except NotFound:
        log.info("Building image %s", tag)
        client.images.build(path=str(ROOT / "app"), tag=tag, buildargs={"APP_VERSION": version}, rm=True)


def start_candidate(client, version, fail):
    """Start the new version next to the old one. No host port, so it can't conflict with anything."""
    name = container_name(version)
    env = {"FAIL_HEALTHCHECK": "true"} if fail else {}
    log.info("Starting candidate %s%s", name, " with FAIL_HEALTHCHECK=true" if fail else "")
    try:
        return client.containers.run(
            f"mockapp:{version}",
            name=name,
            detach=True,
            network=NETWORK,
            environment=env,
            labels={**LABELS, "version": version},
            restart_policy={"Name": "unless-stopped"},
        )
    except APIError as e:
        if e.status_code == 409:
            raise DeployError(f"A container named {name} already exists and is not managed by this tool. "
                              "Rename or remove it, then run again.")
        raise


def wait_healthy(client, candidate, timeout, interval, passes):
    """Poll /health from inside the proxy: the same network path real traffic will use.

    Needs `passes` successes in a row before `timeout` seconds. Returns True or False.
    """
    url = f"http://{candidate.name}:{APP_PORT}/health"
    deadline = time.monotonic() + timeout
    in_a_row = 0
    while time.monotonic() < deadline:
        candidate.reload()
        if candidate.status != "running":
            log.error("Candidate %s stopped (status: %s)", candidate.name, candidate.status)
            return False
        code, out = proxy_exec(client, f"wget -q -T 2 -O- {url}")
        if code == 0:
            in_a_row += 1
            log.info("Health check passed (%d/%d)", in_a_row, passes)
            if in_a_row >= passes:
                return True
        else:
            in_a_row = 0
            log.warning("Health check failed: %s", out or f"wget exit code {code}")
        time.sleep(interval)
    log.error("Candidate not healthy after %ss", timeout)
    return False


# ══════════════════════════════════════════════════════════════════
# Step 6: switch traffic to the new version
# ══════════════════════════════════════════════════════════════════

def write_upstream(client, name):
    """Write a temp file, then mv: an atomic replace inside the proxy container."""
    line = f"server {name}:{APP_PORT};"
    code, out = proxy_exec(client, ["sh", "-c", f"echo '{line}' > {UPSTREAM_FILE}.tmp && mv {UPSTREAM_FILE}.tmp {UPSTREAM_FILE}"])
    if code != 0:
        raise DeployError(f"Could not write {UPSTREAM_FILE}: {out}")


def public_version():
    try:
        r = requests.get(f"{PUBLIC_URL}/version", timeout=2)
        data = r.json()
    except (requests.RequestException, ValueError):
        return None
    if r.status_code != 200 or not isinstance(data, dict) or not isinstance(data.get("version"), str):
        return None
    return data["version"]


def cutover(client, old_name, new_name, new_version):
    """Send traffic to the new container, then prove it from outside. On any problem, switch back."""
    write_upstream(client, new_name)
    try:
        reload_proxy(client)
        for _ in range(5):  # old Nginx workers can answer for a moment after the reload
            if public_version() == new_version:
                break
            time.sleep(1)
        else:
            raise DeployError(f"{PUBLIC_URL}/version does not return {new_version} after cutover")
    except DeployError:
        write_upstream(client, old_name)
        reload_proxy(client)
        raise
    log.info("Cutover done: %s/version returns %s", PUBLIC_URL, new_version)


# ══════════════════════════════════════════════════════════════════
# Rollback: remove the new version (used in Steps 5 and 6)
# ══════════════════════════════════════════════════════════════════

def rollback(client, name):
    """Remove the new container. Traffic never left the old one."""
    log.warning("Rolling back: removing %s", name)
    try:
        container = client.containers.get(name)
    except NotFound:
        return
    if container.labels.get("managed-by") != LABELS["managed-by"]:
        log.error("Not removing %s: it is not managed by this tool", name)
        return
    container.remove(force=True)


# ══════════════════════════════════════════════════════════════════
# Step 7: remove the old version
# ══════════════════════════════════════════════════════════════════

def drain_and_remove(client, old_name, drain):
    """Wait for requests still running on the old container, then stop it gracefully."""
    log.info("Draining %s for %ss", old_name, drain)
    time.sleep(drain)
    old = client.containers.get(old_name)
    old.stop(timeout=10)  # SIGTERM: gunicorn finishes in-flight requests, then exits
    old.remove()
    log.info("Removed old container %s", old_name)


# ══════════════════════════════════════════════════════════════════
# main(): runs Steps 1–7 in order
# ══════════════════════════════════════════════════════════════════

def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-5s %(message)s",
                        datefmt="%H:%M:%S")

    # ── Step 1: read the options ──────────────────────────────────
    args = parse_args()

    # ── Step 2: take the lock (one deploy at a time) ──────────────
    lock = acquire_lock()
    if lock is None:
        log.error("Another deploy is running (lock: %s). Try again when it finishes.", LOCK_FILE)
        return EXIT_LOCKED

    # ── Step 3: check the system, clean up leftovers ──────────────
    try:
        client = preflight()
        log.info("Preflight OK: Docker, network %s, proxy %s", NETWORK, PROXY)
        live_version = reconcile(client)
    except DeployError as e:
        log.error("Preflight failed: %s", e)
        return EXIT_BAD_INPUT
    log.info("Live now: %s", live_version)

    # ── Step 4: is this version already live? ─────────────────────
    if args.deploy == live_version:
        log.info("%s is already live. Nothing to do.", args.deploy)
        return EXIT_OK

    log.info("Deploying %s (timeout %ss, %s passes)", args.deploy, args.timeout, args.passes)
    old_name = read_upstream(client)
    new_name = container_name(args.deploy)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    # ── Step 5: start the new version and test it ────────────────
    #    The old version still gets all the traffic.
    try:
        try:
            ensure_image(client, args.deploy)
        except DockerException as e:
            log.error("Could not build image mockapp:%s: %s", args.deploy, e)
            return EXIT_BAD_INPUT
        try:
            candidate = start_candidate(client, args.deploy, args.fail)
        except (DeployError, DockerException) as e:
            log.error("Could not start %s: %s", new_name, e)
            return EXIT_BAD_INPUT
        healthy = wait_healthy(client, candidate, args.timeout, args.interval, args.passes)
    except Interrupted as e:
        log.error("Stopped by %s before cutover.", e)
        rollback(client, new_name)
        log.error("Deploy of %s CANCELLED. Traffic stayed on %s.", args.deploy, live_version)
        return EXIT_ROLLED_BACK
    if not healthy:
        rollback(client, new_name)
        log.error("Deploy of %s FAILED. Traffic stayed on %s.", args.deploy, live_version)
        return EXIT_ROLLED_BACK

    # ── Step 6: switch traffic to the new version ─────────────────
    #    Ctrl+C can't stop this halfway.
    with no_interrupts():
        try:
            cutover(client, old_name, new_name, args.deploy)
        except DeployError as e:
            log.error("Cutover failed: %s", e)
            rollback(client, new_name)
            return EXIT_ROLLED_BACK
        write_state(args.deploy)

    # ── Step 7: remove the old version ────────────────────────────
    #    The new version is already live.
    try:
        drain_and_remove(client, old_name, args.drain)
    except Interrupted as e:
        log.warning("Stopped by %s during drain. %s is live. %s is still running; "
                    "the next run of deploy.py removes it.", e, args.deploy, old_name)
        return EXIT_OK
    log.info("Deploy of %s SUCCEEDED. %s is live.", args.deploy, args.deploy)
    return EXIT_OK

if __name__ == "__main__":
    sys.exit(main())
