#!/usr/bin/env python3
"""Send requests to the proxy in a loop and count failures. Run it during a deploy to prove zero downtime.

Usage:  python scripts/traffic_test.py --seconds 30
"""
import argparse
import sys
import time
from collections import Counter

import requests

URL = "http://localhost:8080/version"


def main():
    p = argparse.ArgumentParser(description="Hit the proxy in a loop and count failed requests.")
    p.add_argument("--seconds", type=float, default=30, help="how long to run (default 30)")
    p.add_argument("--interval", type=float, default=0.05, help="pause between requests (default 0.05)")
    args = p.parse_args()

    versions = Counter()
    errors = Counter()
    last_version = None
    end = time.monotonic() + args.seconds
    try:
        while time.monotonic() < end:
            try:
                r = requests.get(URL, timeout=2)
                if r.status_code == 200:
                    version = r.json()["version"]
                    versions[version] += 1
                    if version != last_version:
                        print(f"{time.strftime('%H:%M:%S')} traffic: now served by {version}")
                        last_version = version
                else:
                    errors[f"HTTP {r.status_code}"] += 1
            except requests.RequestException as e:
                errors[type(e).__name__] += 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass

    total = sum(versions.values()) + sum(errors.values())
    failed = sum(errors.values())
    print(f"\ntraffic: {total} requests, {failed} failed")
    for version, n in versions.items():
        print(f"  {version}: {n}")
    for error, n in errors.items():
        print(f"  {error}: {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
