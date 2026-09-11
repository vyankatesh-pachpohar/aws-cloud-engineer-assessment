# SCALABILITY.md — Scaling from 5 000 to 50 000 concurrent users

The current design handles a few thousand concurrent users comfortably. Ten-x-ing that is not a single knob; it's a series of decisions across compute, data, cache, edge, and asynchronous work. This doc goes tier by tier.

## 0. Numbers we design against

- Target: **50 000 concurrent users**, ~5–10 requests/s per user during hot bursts.
- Peak throughput target: **200 000 – 500 000 rps** aggregate.
- Latency SLO: **p95 < 300 ms** at the ALB target.
- Availability SLO: **99.95 %** monthly.

Real numbers vary by traffic shape; the point is: pick them *first*, then design.

## 1. Application compute (ECS Fargate)

**Horizontal scaling is already wired.** Two target-tracking policies:
- CPU utilisation 60 % target
- 200 requests/s per target (`ALBRequestCountPerTarget`)

Asymmetric cool-downs: scale-out 60 s, scale-in 300 s. Fast to add, slow to shed — critical for bursty traffic that would otherwise flap.

**What changes at 50 k users:**
- Raise `max_capacity` from 6 (dev) to ~30–60 in prod.
- Vertical: bump task size from 0.5 vCPU / 1 GB to 1 vCPU / 2 GB. Larger tasks amortise the per-task overhead (uvicorn workers, connection pools, JIT warmup).
- Provision baseline capacity with **FARGATE**; overflow to **FARGATE_SPOT** for cost (see COST_OPTIMIZATION.md). Set `base = min_on_demand` on the capacity provider strategy to guarantee a baseline that won't be interrupted.
- Enable **ECS Service Auto Scaling step policies** for shock events (a step of +50 % on p95 > 500 ms for 1 min, over and above the target-tracking policies).

**Deployment strategy at scale.** Rolling deploys with `minimum_healthy_percent = 100` and `maximum_percent = 200` — zero downtime. For riskier changes, add CodeDeploy blue/green with test traffic shift on ALB weighted target groups.

**When ECS is not the answer.** Ultra-spiky workloads (< 5 minutes of load per day) belong on Lambda; steady-state high throughput belongs on ECS. Don't try to serve a 60 s traffic spike with Fargate task boot time — put it on Lambda or pre-warm.

## 2. Load balancer

The ALB itself scales to well past 50 k concurrent users; it's managed by AWS. A few tuning points:

- **Idle timeout** = 60 s (default). Match to app keep-alive slightly higher on the app side (65 s) to avoid the classic "client got a 502 because keep-alive races" issue.
- **Cross-zone load balancing** = on (default for ALB). Absolutely leave it on — otherwise a lopsided AZ ends up over/under loaded.
- **Slow start** on the target group (30 s) so a freshly-scaled-out task gets warmed up gradually. This masters JIT warmup, connection pool priming, and JVM-like cold-start effects.
- **Access logs** to S3 — needed to debug scale events retroactively.

## 3. Database (RDS PostgreSQL)

**This is usually where a 10 × traffic increase breaks first.** The connection ceiling on a db.t3.micro (~87) is the reason.

Tier-by-tier plan:

**Vertical.** Upgrade to `db.r6g.large` (~800 conns) or higher. Storage type `gp3` provides tunable IOPS/throughput; use provisioned IOPS if we hit disk queue depth.

**Read/write split.** Add **1–2 read replicas** in Multi-AZ. Point read-heavy endpoints (`GET /orders/{id}`, listings, reporting) at the reader via a separate SQLAlchemy engine. Writes stay on the primary. Watch replication lag.

**Connection pool management.** With N tasks × M connections/task, we can hit the RDS limit fast. Two levers:
- Keep the app pool small and bounded (already done: 5 + 5 = 10 per task). 30 tasks × 10 = 300 conns.
- Put **Amazon RDS Proxy** in front of RDS if we ever push beyond that. RDS Proxy pools *at the network layer* so 1000 app-side connections may consume 100 real DB connections. Also gives seamless failover.

**Sharding — deferred.** At 50 k concurrent it usually isn't needed for an orders table; a well-indexed Postgres on r6g/r7g handles it. If we hit the wall: shard by customer_id, or move a hot table (event stream) to DynamoDB.

**Aurora.** If the ceiling comes into view, migrate to Aurora PostgreSQL. Storage auto-scales; up to 15 read replicas with < 100 ms replication lag; failover in seconds vs tens of seconds for RDS Multi-AZ.

## 4. Caching (currently: none)

Two tiers to add:

1. **In-memory (per task).** Cache immutable lookups (product catalog, tax rates, SKU metadata). Small `functools.lru_cache` for reference data. Cost: nothing.
2. **Shared cache (ElastiCache Redis).** Cache order reads (`GET /orders/{id}` after write), rate-limit counters, session-y state, feature flags. Deploy as a small cluster mode disabled Redis (r6g.large), then cluster-mode for larger footprints. Set TTLs deliberately — an order rarely changes after 5 minutes.

Rule of thumb: caching typically knocks 60–90 % of read load off RDS for hot endpoints, buying vertical/horizontal headroom cheaply.

## 5. Static content and edge

Public-static assets should never come from the application:
- **S3** for object storage of assets/images/receipts.
- **CloudFront** in front of both S3 (assets) and ALB (API). Even for dynamic content, CloudFront gives us POP-local TLS termination (lower RTT), better DDoS behaviour (Shield Standard included), and easy geo/IP throttling via CloudFront Functions.
- **Cache-Control** headers on the API for `GET /orders/{id}` immediately after write let CloudFront handle repeated reads for a few seconds — turns a burst read of one order into one origin request.

## 6. Asynchronous & background work

The synchronous request path should do the minimum needed to persist the order and respond. Everything else moves off-band:
- **SQS** for durable queues (order-confirmation email, warehouse-fulfilment message, analytics fan-out).
- **Lambda consumers** on SQS — perfect fit: idempotent, small unit of work, spiky in step with orders. This is the "keep serverless where it wins" answer.
- **EventBridge** for pub/sub across services (orders published as events; other bounded contexts subscribe).
- **Step Functions** for multi-step workflows (payment → inventory reservation → fulfilment) so the state machine, not the API, owns the workflow.

**Effect on the API tier:** POST /orders returns as soon as the row is persisted (~30–50 ms), everything else is a queue publish (~5 ms). One synchronous DB round-trip per order → 10 × the app tier's throughput ceiling.

## 7. Network scaling

- **ENI limits.** Each Fargate task gets an ENI. At 60 tasks × several subnet ENI budget, plan subnets big enough. The `/20` subnets in this VPC give ~4000 IPs each — plenty.
- **NAT gateway throughput.** Single NAT peaks around 100 Gbps aggregate, but per-flow the sane operational limit is ~10 Gbps. Beyond that, use one NAT per AZ (already a variable) and/or **VPC endpoints** for ECR, S3, Secrets Manager, CloudWatch (bypasses NAT entirely and costs less egress; see COST_OPTIMIZATION).
- **AZ count.** Grow from 2 → 3 AZs for genuine multi-AZ resilience under load.

## 8. Observability at scale

At 50 k users, blind spots become expensive:
- **X-Ray** or **OpenTelemetry** distributed tracing to see where 500 ms of a request went. In this app it's ready to add: request-id middleware is already in place.
- **Container Insights** on the ECS cluster (already enabled).
- **Percentile SLOs.** Alarms on p95/p99, not just averages, because the tail is where the pain is.
- **Log sampling.** JSON logs are cheap-ish, but at 200k rps INFO logging is not free. Sample INFO to 10 %, keep ERROR at 100 %.
- **Business-level metrics.** Orders/min by SKU / customer segment — as important as CPU%.

## 9. Concrete "10 × plan" summary

| Layer | Now (5k users) | 50k users |
|-------|----------------|-----------|
| ALB | as-is | as-is (managed) |
| ECS tasks | 2 (0.5 vCPU) | 30–60 (1 vCPU) with SPOT for excess |
| ECS scaling | CPU 60 %, 200 rpt | + step policy on p95 |
| RDS | db.t3.micro, single AZ | db.r6g.large Multi-AZ + 1–2 read replicas |
| DB connections | 10 per task | 10 per task + RDS Proxy if > ~300 conns |
| Cache | none | ElastiCache Redis (r6g.large) |
| Async | none | SQS + Lambda consumers |
| Edge | ALB only | CloudFront in front |
| Observability | logs + metrics | + X-Ray, tail sampling, business dashboards |
| Cost lever | on-demand only | Savings Plans + FARGATE_SPOT + VPC endpoints + lifecycle |

## 10. Auto-scaling policies — the ones I would use

- **ECS service:** target-tracking on CPU 60 % + `ALBRequestCountPerTarget` at 200; step policy on p95 > 500 ms (adds 50 % capacity).
- **RDS read replicas:** target-tracking on Aurora Serverless (if used) or manual scale-out with a runbook (RDS non-Aurora doesn't auto-scale replicas).
- **Aurora Serverless v2** as the cost-optimal option for RDS when workload is bursty.
- **ElastiCache:** cluster-mode enabled Redis with shard rebalance policies; scale replicas per shard.
- **CloudFront:** managed; no explicit scaling needed.
- **Lambda consumers:** reserved concurrency to protect RDS; scale up event-source mapping batch size, not concurrency, first.

Every one of these knobs should be turned only after telemetry says so — never speculatively.
