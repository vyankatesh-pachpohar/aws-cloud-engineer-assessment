# MIGRATION.md — Serverless → Containerized (Zero/Minimal Downtime)

**From:** Users → API Gateway → Lambda → DynamoDB/RDS
**To:**   Users → Route 53 → WAF → ALB → ECS Fargate → RDS PostgreSQL

The migration is done as a **gradual, weighted DNS + parallel-stack cut-over**, not a big-bang. At every step both stacks are live; we shift a percentage of real traffic and watch the SLOs. If anything looks wrong we shift back — DNS is our steering wheel.

## Guiding principles

1. **Both stacks answer the same URL.** No breaking API contract changes during the shift. New contract changes go behind versioned paths or feature flags and are shipped *after* the migration finishes.
2. **Idempotent writes end-to-end.** Every `POST /orders` requires an `Idempotency-Key` header. The DB has a `UNIQUE` constraint on that column. A retry — from a client, from ALB, from the DNS shuffle — cannot create a duplicate.
3. **One source of truth for data.** Both stacks read/write the *same* database throughout the migration. There is no dual-write, no eventual reconciliation. Data migration (if the underlying engine changes) happens **before** traffic shifting, using DMS with CDC.
4. **Reversible at every step.** Every phase has a documented rollback whose max blast radius is one DNS TTL.
5. **Observability first.** Dashboards, alarms and per-stack tagging exist *before* the first byte of production traffic hits ECS.

## Phase 0 — Assessment (before touching anything)

- Inventory every Lambda: handler, concurrency, timeout, memory, deps, VPC config, IAM policy, env vars, cold-start p50/p95, invocation source.
- Inventory data: engine, size, RPS, replication, backups, PITR window, biggest tables, hottest indexes.
- Baseline SLOs from CloudWatch / X-Ray: p50, p95, p99, error rate, throughput. These become the **rollback thresholds**.
- Map upstream/downstream: WAF, custom authorizers, API-Gateway request/response mappings, usage plans, API keys, quotas, throttles.
- Cost baseline per Lambda + per env.

Output: a one-pager per Lambda with "what it does + what it depends on + who calls it".

## Phase 1 — Target build (dark, no traffic)

- Provision the target stack from Terraform in a **separate account** (or at minimum, a separate namespace). VPC, ALB, ECS, RDS, WAF, secrets, monitoring — everything except the DNS switchover.
- Port the handler to FastAPI. Same request/response shapes, same error codes, same headers, same content-type. Preserve any custom API-Gateway response mappings inside the app so clients see identical payloads.
- Health check `/health` verifies DB reachability with `SELECT 1`.
- Idempotency-Key handling (unique DB constraint + fast-path lookup).
- Structured JSON logs including a stack tag: `"stack": "ecs" | "lambda"`.

## Phase 2 — Database migration (only if the engine changes)

If the target uses a different engine (Dynamo → Postgres, MySQL → Aurora, etc.):

1. **Initial full load with AWS DMS.** Snapshot → target.
2. **Turn on Change Data Capture (CDC).** DMS replicates ongoing writes from source → target until the cut-over.
3. **Verify continuously.** Row counts + checksum on a sample of keys; DMS validation task.
4. **Freeze window at cut-over:** briefly stop writes (seconds), let CDC drain to zero lag, flip the app config to point to the target, resume writes. Or use dual-write for a short window if a hard freeze is unacceptable.

If both stacks talk to the **same** database (recommended for this assessment), skip Phase 2 and jump to traffic migration.

## Phase 3 — Load balancing & DNS strategy

- Give the ALB a friendly hostname: `api-ecs.example.com` → the ALB DNS name (Route 53 alias, cost-free, no CNAME).
- Keep the API-Gateway invoke URL as-is: `api-lambda.example.com` → API Gateway.
- Public hostname `api.example.com` uses a **Route 53 weighted policy** with two records:
  - `api.example.com` → alias → `api-lambda.example.com`, weight 100
  - `api.example.com` → alias → `api-ecs.example.com`,    weight 0
- Set the record TTL to **60 seconds** *at least an hour before* the first shift, so any prior long-cached values expire.

Progressive shift:
| Step | Lambda | ECS  | Hold | Watch for |
|------|--------|------|------|-----------|
| 0    | 100    | 0    | —    | dark canary from synthetic monitor |
| 1    | 95     | 5    | 30 min | 5xx delta, p95 delta |
| 2    | 75     | 25   | 1 h   | RDS conns, throttling |
| 3    | 50     | 50   | 2 h   | steady state |
| 4    | 25     | 75   | 2 h   | approach full |
| 5    | 0      | 100  | 24 h  | keep Lambda hot for rollback |

## Phase 4 — Traffic migration mechanics

**Duplicate requests / retries.**
- Root cause is usually: a client SDK retry, an ALB idle-timeout that closed a connection mid-response, or a client seeing two different DNS answers around the TTL boundary.
- The system-level fix is the `Idempotency-Key` header + DB unique constraint (built into the API). A duplicate POST returns the *original* order with HTTP 200; the DB never has two rows.
- Also: keep server keep-alive > client keep-alive to avoid the classic "connection reset during body write" retry.

**Data consistency.**
- Both stacks target the same primary. There is no split-brain window.
- All writes are Idempotency-Key-guarded. Non-idempotent writes (rare) are moved behind SQS + a dedicated worker before the migration begins.

**Rollback.**
- Set the weighted record back to (100 / 0). Within one TTL (60 s) new connections land on Lambda.
- Because both stacks share the DB, no data reconciliation is needed.
- Keep the Lambda stack **fully deployed and warm** for at least 24 h after 100 % ECS.

## Phase 5 — Monitoring during migration

Dashboards side-by-side, per stack:
| Signal | Lambda | ECS |
|--------|--------|-----|
| Requests | `AWS/Lambda Invocations` | ALB `RequestCount` |
| Errors   | `Errors` / `Throttles`    | ALB `HTTPCode_ELB_5XX_Count` + target 5xx |
| Latency  | `Duration` p50/p95        | ALB `TargetResponseTime` p50/p95 |
| Sat.     | `ConcurrentExecutions`    | ECS CPU/mem, task count |
| DB       | RDS `DatabaseConnections`, CPU, read/write latency |

**Rollback triggers** (any one → shift weights back and open an incident):
- p95 latency on ECS > 1.5 × Lambda baseline for 5 min.
- 5xx rate on ECS > 1 % of requests for 5 min.
- RDS connections > 80 % of `max_connections` or CPU > 85 % for 10 min.
- Any customer report of duplicate orders that isn't explained by an Idempotency-Key replay.

## Phase 6 — Post-migration validation

- 24 h at 100 % ECS with SLOs green.
- Reconcile order counts by (customer × hour) between the two stacks (should be identical for the overlap window).
- Announce EOL for API Gateway/Lambda; hold for one week for rollback capacity.
- Delete API Gateway resources; drop unused IAM roles; leave the Lambda code in git for reference.
- Cost + latency report vs the baseline.

## Assumptions

- API surface is unchanged during the migration window.
- Same primary database is used by both stacks; if not, Phase 2 (DMS + CDC) is required.
- Clients respect `Idempotency-Key` (if not, we mint one on the API-Gateway proxy for legacy clients).
- DNS TTL of 60 s is acceptable to the business (cache-friendliness discussed in Phase 3).
