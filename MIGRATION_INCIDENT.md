# MIGRATION_INCIDENT.md — 75 % Lambda / 25 % ECS traffic-shift incident

## Scenario recap

Mid-migration. Weights are Lambda 75 % / ECS 25 %. In the last 15 minutes:
- Overall latency is up.
- 5xx rate is rising.
- `RDS DatabaseConnections` is climbing steeply.
- Customer support is reporting **duplicate orders**.

## 1. What do I investigate first — and in what order?

I don't touch the traffic split yet. My priority order is:
1. **Are the duplicates real, or Idempotency-Key replays returning 200?** (query the DB; see §5.)
2. **Which stack is producing the 5xx?** ECS-only, Lambda-only, or both? Answer decides whether we roll back the shift or dig into a shared dependency.
3. **Is RDS the bottleneck or the victim?** Connections rising *causes* new symptoms, but is it a cause (pool leak in ECS) or an effect (retries multiplying load)?
4. **Anything else changed in the last 30 minutes?** Deploys, feature flags, batch jobs, WAF rule updates, sudden marketing traffic.

The point of that ordering: rule out a false alarm (#1), attribute the failure (#2), find the amplifier (#3), then correlate with change (#4). Only then decide continue/pause/rollback.

## 2. Which AWS metrics and logs do I look at?

**ALB (target group split by stack)**
- `RequestCount`, `HTTPCode_Target_5XX_Count`, `HTTPCode_ELB_5XX_Count`, `TargetResponseTime` (p50/p95/p99), `UnHealthyHostCount`.
- Compare ECS-target-group vs Lambda numbers side-by-side.

**API Gateway / Lambda**
- `4XXError`, `5XXError`, `Latency`, `IntegrationLatency`, `Throttles`, `ConcurrentExecutions`.
- Lambda logs (`/aws/lambda/<fn>`) filtered on `ERROR`, `Task timed out`, `Init Duration`.

**ECS**
- `CPUUtilization`, `MemoryUtilization`, `RunningTaskCount`, deployment events on the service.
- Container logs (`/aws/ecs/<service>`): filter for `OperationalError`, `503`, `IntegrityError`, `pool timed out`.

**RDS**
- `DatabaseConnections` vs `max_connections` (per t3.micro ≈ 87; per r6g.large ≈ 823).
- `CPUUtilization`, `ReadLatency`, `WriteLatency`, `Deadlocks`, `DiskQueueDepth`.
- Performance Insights → top waits (`ClientRead`, `Lock`, `IO`). Enhanced Monitoring for OS-level.
- `postgresql.log` in CloudWatch: slow queries, connection storms, lock waits.

**Cross-cutting**
- WAF: sample requests, `AllowedRequests` vs `BlockedRequests`, any rate-limit action spiking.
- Route 53: any DNS anomalies (health-check flips).
- CloudTrail: recent Config / IAM / SG / TG changes.

## 3. How do I identify the root cause?

Compare the two stacks under the *same* load and follow the divergence.

**Signal patterns → hypotheses**

| Pattern | Likely cause |
|---------|---------------|
| ECS-only 5xx + ECS CPU low + RDS conn ↑ | Pool leak in ECS or wrong pool sizing (each task oversubscribing) |
| ECS-only 5xx + ECS CPU pegged | Under-provisioned tasks / autoscaler not keeping up |
| Both stacks slow + RDS CPU ↑ | Query regression, missing index, table bloat, autovacuum lag |
| Both stacks 5xx + RDS `too many connections` | RDS at conn limit — a downstream constraint on both |
| Duplicates AND ECS 5xx | Retries multiplying: ALB 5xx → client retries → 5xx again; each retry may hit a *different* stack and (without idempotency) create a second order |
| Only Lambda 5xx | An older-stack regression; migration is not at fault |
| Sudden spike in requests | Marketing / bot / retry storm — orthogonal to the migration |

**Concrete queries I run**

CloudWatch Logs Insights on the app log group:
```
fields @timestamp, request_id, level, message, order_id
| filter level = "ERROR" or status >= 500
| stats count() by bin(1m), message
```

Postgres (via psql/session-manager to a bastion, or `aws ecs execute-command`):
```sql
-- who's holding connections
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
-- is a long-running query blocking others?
SELECT pid, now()-query_start AS age, state, query
  FROM pg_stat_activity WHERE state != 'idle' ORDER BY age DESC LIMIT 10;
```

Task-level CPU / memory: `ECS/ContainerInsights`; per-task via `aws ecs describe-tasks` → CloudWatch Container Insights.

**My best guess before looking**, based on the symptom cluster: connections-per-request in ECS is higher than budgeted (probably a bug in pool sizing or lifespan), which pushes RDS toward its connection ceiling, which causes 5xx, which causes client retries, which explains the duplicate reports on any endpoint that isn't idempotent.

## 4. Continue, pause, or roll back?

The decision is data-driven and pre-committed (see MIGRATION.md §5 rollback triggers). I don't debate — I act on the rule and investigate in parallel.

- **Roll back the shift** (weights → 100/0) if **any of**:
  - 5xx rate on ECS > 1 % for 5 min.
  - p95 latency on ECS > 1.5 × Lambda baseline for 5 min.
  - RDS conns > 80 % of `max_connections` or CPU > 85 % for 10 min.
  - A duplicate order is confirmed as an actual double-write (see §5).
- **Pause the shift** (freeze at 75/25) if symptoms are mild: no SLO breach yet, but drift in the right direction. Buys time to investigate without customer impact.
- **Continue** only if the elevated numbers are explainable, transient, and not from ECS.

Because both stacks share the DB, rolling back the shift is safe and cheap — no data reconciliation needed. One DNS TTL later (60 s) the pressure is off ECS and I can investigate calmly.

## 5. Are duplicate orders a real problem?

The Idempotency-Key + DB unique constraint means a repeated `POST /orders` with the same key returns the original order with **HTTP 200** (not 201). So there are three cases:

1. **Client got 200 both times** → not a duplicate; idempotency did its job. Educate support; instrument the app to log `"idempotent_replay": true` (already present in `main.py`).
2. **Client got 201 twice from *different* keys but the same intent** → the client didn't send a stable Idempotency-Key. That's a **client contract issue** — the guarantee is only end-to-end if the key is stable per business intent. Options: (a) enforce the header on the ALB/WAF, (b) mint a key on API Gateway from a hash of body + auth context for legacy clients.
3. **Two rows in `orders` for the same `idempotency_key`** → impossible in Postgres given the `UNIQUE` constraint. If it happened, the constraint is missing (migration bug) — fix immediately.

The prevention design, in one paragraph: **API contract requires `Idempotency-Key`, the DB has a UNIQUE index on it, and the app returns the pre-existing order on a duplicate key.** Both the fast-path lookup and the `IntegrityError` race path are implemented (see `app/main.py::create_order`).

## 6. How do I ensure data consistency across systems?

- **Single source of truth for orders.** Both stacks read/write the same primary RDS. No dual-write, no async reconciliation.
- **Idempotent writes.** Enforced above.
- **Read your writes.** If the client hits ECS then Lambda then ECS again, the DB is the same, so the sequence is coherent. If a read replica is introduced, tag reads that require read-your-writes semantics and pin them to the primary (or use `SET session_replication_role`).
- **Auditability.** Every order carries `created_at` and, if extended, a stack tag. Regular reconciliation query for the migration window:
  ```sql
  SELECT date_trunc('minute', created_at), count(*)
    FROM orders WHERE created_at > now() - interval '2 hours'
    GROUP BY 1 ORDER BY 1;
  ```

## 7. What would make me stop the migration entirely?

- Data-integrity signal we can't explain within 30 minutes.
- The failure surface is inside a shared dependency I can't upgrade in the migration window (e.g. RDS engine bug requires a version bump).
- Rollback itself is showing symptoms (rare — implies infra drift).
- SLO error budget for the month is exhausted.

Stop, roll back to 100/0, write a public postmortem, address the root cause, redo Phase 1 verification, then start the traffic shift again from step 1.
