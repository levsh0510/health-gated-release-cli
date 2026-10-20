# Architecture

## Part A: Local implementation

### Routing: why Nginx

Nginx is the only public entry point (`localhost:8080`). The app containers publish no ports, so v1 and v2
can run at the same time and never fight over a port.

Nginx reads the address of the live app from one small file inside the proxy container:
`server mockapp-v1-0-0:5000;`. To switch versions, the CLI rewrites that line and runs `nginx -s reload`.
A reload is graceful. Nginx starts new workers with the new config, and the old workers finish their
open requests and then exit. No connection is dropped.

I chose Nginx over Traefik or HAProxy because the switch is one line in one file. It is easy to
read, test (`nginx -t`) and explain. Traefik can switch by itself from container labels, but that
hides the moment of the switch, and I wanted to check it myself.

### State: how the tool knows what is live

| What | Where | Used for |
|---|---|---|
| Where traffic goes | The Nginx upstream file | **The truth.** It decides what users get. |
| Which version is live | `state/active.json` | A copy for people and scripts. Written atomically (temp file, then rename), so a crash never leaves a half-written file. |
| Which containers are ours | Docker labels (`app`, `managed-by`, `version`) | Finding leftovers. |
| One deploy at a time | `state/deploy.lock` with `flock` | The second deploy exits with code 3. The OS frees the lock if the process dies, even with `kill -9`. |

At the start of every run, the CLI **reconciles**. It reads the upstream file, treats that container as live,
removes every other container with our label, and repairs `active.json` if it disagrees. So after
any crash, the fix is to run the same command again.

### How downtime is prevented

1. Start the new container next to the old one. The old one keeps serving.
2. Health check from inside the proxy container, so it uses the same network path real traffic will use.
   It needs 3 passes in a row before the timeout. One lucky pass is not enough.
3. Write the new upstream line, run `nginx -t`, then reload gracefully.
4. Check `localhost:8080/version` from outside. If it does not return the new version within 5 seconds,
   switch back and roll back.
5. Wait 5 seconds (drain), then stop the old container with SIGTERM. Gunicorn finishes its open
   requests before it exits. Then remove it.

Rollback is cheap, because the old version is never touched until the new one has proved itself.
If the health check fails, or Ctrl+C arrives before step 3, the CLI removes only the new container and
exits with code 1. Ctrl+C during step 3 is ignored until the switch is done, so the switch is never half finished.

Measured result: 401 requests during a deploy, 0 failed.
