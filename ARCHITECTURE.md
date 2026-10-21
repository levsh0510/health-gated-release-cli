# Architecture

## Part A: Local implementation

### Routing: why Nginx

Nginx is the only public entry point (`localhost:8080`). The app containers publish no ports, so v1 and v2
can run at the same time and never fight over a port.

Nginx reads the address of the live app from one small file inside the proxy container:
`server mockapp-v1-0-0:5000;`. To switch versions, the CLI rewrites that line and runs `nginx -s reload`.
A reload is graceful. Nginx starts new workers with the new config, and the old workers finish the
requests they already have and then exit.

I chose Nginx over Traefik or HAProxy because the switch is one line in one file. It is easy to
read, test (`nginx -t`) and explain. Traefik can switch by itself from container labels, but that
hides the moment of the switch, and I wanted to check it myself.

### State: how the tool knows what is live

| What | Where | Used for |
|---|---|---|
| Where traffic goes | The Nginx upstream file | **The truth.** It decides what users get. |
| Which version is live | `state/active.json` | A copy for people and scripts. Written atomically (temp file, then rename), so a crash never leaves a half-written file. |
| Which containers are ours | Docker labels (`app`, `managed-by`, `version`) | Finding leftovers. A container must have both `app` and `managed-by` to be touched. |
| One deploy at a time | `state/deploy.lock` with `flock` | The second deploy exits with code 3. The OS frees the lock if the process dies, even with `kill -9`. |

At the start of every run, the CLI **reconciles**. It reads the upstream file, treats that container as live,
checks that `localhost:8080/version` shows that version, removes every other container of ours, and repairs
`active.json` if it disagrees. If the public check fails, it removes nothing. So after
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

Rollback is cheap, because the old version is never touched until the new one has proved itself. If the switch
itself fails, the CLI switches back and checks that the old version is public before it removes anything.
If it cannot prove that, it keeps both containers, prints what to check, and exits with code 4.
If the health check fails, or Ctrl+C arrives before step 3, the CLI removes only the new container and
exits with code 1. Ctrl+C during step 3 is ignored until the switch is done, so the switch is never half finished.

Measured result: about 400 requests during a deploy, 0 failed. This is a continuity check for simple
requests, not a proof for every kind of long connection.

## Part B: AWS enterprise mapping

The same workflow as the local tool. AWS services do each job.

### Infrastructure

![AWS infrastructure](docs/aws-infrastructure.svg)

| Local | AWS |
|---|---|
| `mockapp-vX` containers | ECS on Fargate, one task per container, in two Availability Zones |
| Nginx proxy | Application Load Balancer with a target group and a `/health` check |
| `localhost:8080` | Route 53 alias to the ALB, with HTTPS |

- **Tasks are private.** They have no public IP. Only the ALB can reach them: the task security group allows port 5000
  from the ALB security group and nothing else.
- **No internet path.** The VPC has an internet gateway for the public subnets only. The private subnets have no route
  to it, and there is no NAT gateway.
- **AWS services through VPC endpoints.** Interface endpoints for ECR, CloudWatch Logs and Secrets Manager, and an S3
  gateway endpoint (ECR keeps image layers in S3). Traffic to them stays on the AWS network.
- **If the app ever needs the public internet** (a third-party API), add a NAT gateway. It is not needed here.

### CI/CD and canary deployment

![CI/CD and canary deployment](docs/aws-cicd-deployment.svg)

| Local | AWS |
|---|---|
| `deploy.py` | GitHub Actions starts a CodeDeploy blue/green deployment |
| Health gate | ALB health check on `/health`, 3 passes in a row. CodeDeploy waits until green is healthy. |
| Switch upstream and reload | CodeDeploy moves the ALB listener weights between the blue and green target groups |
| Drain, then SIGTERM | ALB deregistration delay (30 s) and ECS `stopTimeout` |
| `flock` | CodeDeploy runs one deployment per service at a time |
| Exit code 1 | A rolled-back deployment fails the CI job |

- **Canary:** 10% of traffic for 5 minutes, then 100% (`CodeDeployDefault.ECSCanary10Percent5Minutes`).
- **Rollback trigger:** a CloudWatch alarm on the 5xx rate of the green target group, for example above 2% for
  2 of 3 minutes. It is attached to the deployment group, so an alarm sends traffic back to blue.
- **Instant rollback:** blue keeps running until the deployment succeeds, so rollback is moving the weight back.

### Security

| Area | Choice |
|---|---|
| IAM | One role per job: task execution (pull image, write logs, read named secrets), task (what the app needs), CodeDeploy. CI uses GitHub OIDC: no stored keys, limited to this repo and branch. |
| Network | ALB in public subnets. Tasks in private subnets with no public IP. The task security group allows port 5000 only from the ALB. VPC endpoints, so no internet path. |
| Secrets | Secrets Manager with KMS and rotation, injected at task start. Never in the image or the repo. |
| Images | ECR scan on push and immutable tags. |

### High availability and disaster recovery

![High availability and disaster recovery](docs/aws-disaster-recovery.svg)

- **One zone fails:** the ALB and at least 2 tasks run in 2 Availability Zones. ECS replaces a failed task by itself.
- **A whole region fails:** the stack is written in **Terraform**, one module run once per region with a `region`
  variable. It is small, so a new region is built from the same code. No standby runs in the second region, so
  downtime during recovery is accepted.
- **Ready in advance, with no servers running:** ECR image replication, Secrets Manager replica secrets, and an
  S3 bucket in region 2 for the Terraform state of region 2. Each region has its own state, so region 2 never
  needs region 1.
- **Alert:** a Route 53 health check on the public URL raises a CloudWatch alarm, and SNS notifies the on-call.
  A person starts the recovery.
- **Recovery:** run Terraform for region 2 (a CI job). Terraform then points the Route 53 alias to the new ALB.
  When region 1 is back, switch the alias back and destroy region 2.
- **Estimate:** recovery in about 15 to 20 minutes. Data loss: none, because the app is stateless.
