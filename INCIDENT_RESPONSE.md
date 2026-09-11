# INCIDENT_RESPONSE.md — API returning HTTP 503 after a deploy

**Scenario:** deploy went out; users get 503 from the API.

The order of checks below is *engineered order*, not random: check the fastest-to-diagnose things first, and check the layers closest to the change first (a deploy just happened, so app / task / target-group changes are more suspect than VPC).

## 0. Immediate first minute (before diagnosis)

1. **Confirm the outage.** `curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://<alb>/health` from outside your own network.
2. **Freeze:** halt any in-flight deploys (`aws ecs update-service --force-new-deployment` off; disable the GH Actions deploy env).
3. **Decide rollback thresholds now.** If nothing improves in 10 minutes → rollback to the last-known-good task definition. Set a timer.
4. **Open the ops channel and a scratch doc.** Timestamp every action. Others will need this.

## 1. Is the failure at the ALB, target group, or app?

`curl -v https://<alb>/health` — read the status *and* which layer answered.
- **503 from ALB directly** (e.g. `Server: awselb/2.0`) → the target group has no healthy targets. Skip to §3.
- **503 with an app-shaped JSON body** (`{"detail":"database unavailable"}`) → the app is up and returning 503 deliberately. Skip to §6.
- **502 / 504** → the app didn't respond correctly (crash mid-response / timeout). §5.
- **Timeouts / connection refused** → the ALB may be broken, WAF blocking, or SG mis-set. §2.

## 2. ALB and WAF sanity

- `aws elbv2 describe-load-balancers` — is the ALB `active`?
- `aws elbv2 describe-listeners` — HTTP 80 and (if HTTPS) 443 present, correct default actions?
- ALB SG allows 0.0.0.0/0:80 and :443 inbound? Check egress to targets on the container port.
- WAF WebACL associated to the ALB? Any rule blocking (WAF CloudWatch metrics `BlockedRequests` spiking)?
- If WAF is in shadow, this rules WAF out fast.

## 3. Target group health

`aws elbv2 describe-target-health --target-group-arn <TG_ARN>` — look at `State` and `Reason`:
- `initial` → waiting on health checks; give it `HealthyThresholdCount × Interval` seconds.
- `unhealthy` with `Target.FailedHealthChecks` → the app is booted but `/health` isn't returning 200. Go to §6.
- `unhealthy` with `Target.Timeout` → app is not answering on the container port. §5.
- `draining` → deploy is happening; targets are being replaced. Wait one round; if it never converges, §4.
- No targets registered → ECS didn't attach them. §4.

**Health-check settings sanity:** path (`/health`), port (`8000`), protocol (HTTP), matcher (200), interval, thresholds. Mismatch here is a classic "everything looks fine but ALB reports unhealthy".

## 4. ECS service and task lifecycle

`aws ecs describe-services --cluster <c> --services <s> --query 'services[0].{running:runningCount,desired:desiredCount,events:events[0:8]}'`
- `runningCount < desiredCount` → tasks aren't starting or aren't staying up. Read the service **events** list — it's the single most useful field in an ECS incident.
- Common event messages:
  - `unable to place a task because no container instance met all of its requirements` — Fargate capacity issue (rare) or subnet ENI limits.
  - `service … has stopped 3 tasks` — the tasks are crashing; go to §5.
  - `service registered 2 targets in target-group` — targets are attaching; healthiness is now §3's problem.

`aws ecs list-tasks --cluster <c> --service-name <s> --desired-status STOPPED` → get a task ARN → `aws ecs describe-tasks` → `stoppedReason` and `containers[0].reason`:
- `Essential container in task exited` → container crashed. §5.
- `CannotPullContainerError` → ECR IAM (execution role), ECR repo policy, or NAT/VPC endpoint issue.
- `ResourceInitializationError` → missing secret / KMS permission / bad log-group ARN.

## 5. Application logs (the fastest signal)

`aws logs tail /aws/ecs/<service> --since 15m --follow`

What to look for:
- **Startup failure** (crash before serving) → app is dead. Likely: bad env var, missing secret, wrong image tag, Python import error.
- **`OperationalError`** (SQLAlchemy) → DB unreachable — SG, DNS, credentials. §7.
- **`OSError [Errno 98] address already in use`** → two workers on the same port; misconfigured `--workers`.
- **`ModuleNotFoundError`** → the image is old / broken.
- **500s** in access log with no upstream error → app bug from the deploy.
- **No logs at all** → the log driver in the task def isn't wired, or the task never started. Fall back to §4's stopped-reason.

`aws ecs execute-command --cluster <c> --task <arn> --command "/bin/sh" --interactive` if `enableExecuteCommand=true` — get a shell inside a running task.

## 6. App-level 503 (self-reported)

The app returns 503 from `/health` when `SELECT 1` fails. That means:
- **RDS unreachable** (SG, subnet route, endpoint typo, RDS restarting) → §7.
- **DB creds wrong** (secret updated but task not restarted; wrong secret ARN in task def) → check Secrets Manager version vs task env.
- **Connection pool exhausted** → many `pool timed out` in logs; look at RDS `DatabaseConnections`. Was there a leak in this release? Roll back.

## 7. Networking and RDS

- From a task shell (see §5): `getent hosts <rds-endpoint>` — DNS resolves? `nc -vz <rds-endpoint> 5432` — TCP reachable?
- SGs: RDS SG must allow ingress **from the ECS tasks SG** (SG-to-SG). Double-check after any SG edits during deploy.
- Subnet route tables: private subnets must have a route to NAT for ECR pulls; RDS is in-VPC so no NAT needed for its traffic.
- RDS state: `available`? Not in `modifying` or `rebooting`? `aws rds describe-db-instances`.
- `DatabaseConnections` vs `max_connections`? On t3.micro it's ~87. If we're near the ceiling, the app can't open a new connection and the health check trips.

## 8. Deployment configuration and rollback

- `aws ecs describe-services` → `deployments`: is a new one still `IN_PROGRESS`? Is the old one still `PRIMARY` because the new one failed?
- The service has `deployment_circuit_breaker { rollback = true }` — a failed deploy auto-rolls back. Look for a "circuit breaker triggered a rollback" event.
- Manual rollback: identify the last-good task def and re-point the service to it.
  ```
  aws ecs update-service --cluster <c> --service <s> --task-definition <family:revision>
  aws ecs wait services-stable --cluster <c> --services <s>
  ```

## 9. Auto scaling

Under a traffic spike, 503s can be a scale-out shortfall:
- `RunningTaskCount` and `DesiredCount` on the ECS service — are we at `max_capacity`?
- `TargetTrackingScaling` metrics: CPU stays above target because we're capped at `max_capacity`.
- Fix: raise `max_capacity`, redeploy scaling policies. Under sustained load also bump task CPU/memory (vertical) — horizontal alone can hit RDS conn limits.

## 10. Verify recovery

Every check above should be followed by a re-test:
```
for i in {1..10}; do curl -s -o /dev/null -w '%{http_code}\n' https://<alb>/health; sleep 3; done
```
Ten consecutive 200s + all TG targets `healthy` + alarms in `OK` = closed.

## Postmortem

Once green:
- Timeline from ops-channel timestamps.
- Root cause (single sentence).
- Contributing factors (what made it worse or slower to detect).
- Detection: what caught it, what should have.
- Corrective actions: fix + guardrail so this can't recur silently.
- Owners and dates. No blame.
