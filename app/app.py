"""Mock app: reports its version and health.

APP_VERSION is baked into the image at build time.
FAIL_HEALTHCHECK=true makes /health return 500, to test the rollback path.
"""
import os

from flask import Flask, jsonify

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "unknown")
FAIL_HEALTHCHECK = os.environ.get("FAIL_HEALTHCHECK", "false").lower() == "true"


@app.get("/version")
def version():
    return jsonify(version=VERSION)


@app.get("/health")
def health():
    if FAIL_HEALTHCHECK:
        return jsonify(status="unhealthy", version=VERSION), 500
    return jsonify(status="ok", version=VERSION), 200
