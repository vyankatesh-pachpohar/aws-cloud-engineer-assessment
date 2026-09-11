# COST_OPTIMIZATION.md — Cost optimisation

Cost is a first-class quality attribute. The recommendations below are ordered from **highest impact per hour of engineering time** down. Numbers are ap-south-1 (Mumbai) on-demand prices at the time of writing; use them as directional not exact.

## Executive summary (top 5)

1. **Right-size EC2 / Fargate + auto scaling in on**  — biggest lever, near-zero risk.
2. **Fargate Spot for 70–90 % of the fleet** — up to 70 % off Fargate hours.
3. **VPC endpoints for S3 / ECR / Secrets Manager** — kills a large chunk of NAT egress cost.
4. **Compute Savings Plans (1-year, no upfront)** — 30–40 % off the on-demand baseline.
5. **S3 lifecycle + CloudWatch log retention** — small monthly savings that compound; and stop paying to store audit noise.

## 1. Compute right-sizing

**Symptom of over-provisioning:** average CPU < 25 % for a week. Symptom of under-provisioning: throttling / autoscaler pinned at max.

Actions on this app:
- Task size: start at **0.5 vCPU / 1 GB**. Only step to 1 vCPU when CPU consistently trends > 60 % after horizontal scale has done its work.
- **CloudWatch Container Insights** already on — use the built-in per-service CPU/mem visualisation as the ground truth.
- **AWS Compute Optimizer** for RDS/EC2 recommendations; check monthly.

Real-world data from my current company: a 40 %+ AWS spend reduction across services came almost entirely from right-sizing + lifecycle policies + turning off the always-on non-prod resources. No exotic optimisations.

## 2. Auto scaling — the free lunch

Auto scaling isn't just about performance — it's the difference between paying for peak or paying for average.

- **ECS service** target-tracking (already configured): CPU 60 %, requests-per-target 200. Add a step policy for p95 latency to react to shocks.
- **RDS storage auto scaling**: `max_allocated_storage` (already set) grows storage automatically; you don't pay for future headroom you don't need yet.
- **RDS instance scheduling** (dev/test only): stop non-prod RDS at night/weekends. `db.t3.micro` is cheap but dozens of them add up.

## 3. Fargate Spot

Fargate Spot gives up to **70 % off** on-demand pricing for tasks that tolerate interruption (2-minute warning).

Design pattern already wired in `modules/ecs`:
```
default_capacity_provider_strategy {
  capacity_provider = "FARGATE"
  weight            = 1
  base              = var.min_on_demand   # baseline on-demand tasks
}
```
Add a second entry with `FARGATE_SPOT` and a higher weight in prod:
```
{ capacity_provider = "FARGATE_SPOT", weight = 3 }
```
For a stateless API with fast startup, Spot interruption is a non-event: the ALB deregisters, ECS launches a replacement, in-flight requests drain in the deregistration delay.

**Do not put** the last two on-demand tasks on Spot; keep a baseline that can't be pulled out from under you.

## 4. NAT gateway egress and VPC endpoints

NAT is easy to overlook and often the second-largest surprise on a bill.
- NAT charges **per hour** and **per GB processed**.
- Every ECR pull, every Secrets Manager fetch, every CloudWatch Logs push from a task in a private subnet crosses NAT — a ~200 MB image pulled by 30 fresh tasks is 6 GB per deploy.

**Fix:** add VPC endpoints (gateway type for S3 & DynamoDB — free; interface for ECR, ECR API, Secrets Manager, CloudWatch Logs, SSM — small per-hour but no per-GB cross-NAT).

**Endpoints to add first (typical ROI within days):**
- `com.amazonaws.<region>.s3` (gateway)
- `com.amazonaws.<region>.ecr.dkr` (interface)
- `com.amazonaws.<region>.ecr.api` (interface)
- `com.amazonaws.<region>.secretsmanager` (interface)
- `com.amazonaws.<region>.logs` (interface)

These aren't in this Terraform yet (kept the module surface small for the assessment); adding them is one module = ~20 lines each.

## 5. RDS right-sizing and storage

- **Right instance class.** t3/t4g burstable for dev; r-family (memory-optimised) for prod. Graviton (arm64) r6g/r7g gives ~20 % better price/perf.
- **Storage type gp3** (this repo uses it): baseline 3000 IOPS / 125 MB/s included; scale IOPS separately from GB, unlike gp2.
- **Reserved Instances (1- or 3-year) for the baseline production DB.** 30–60 % off list. Combine with Savings Plans on compute for the biggest hit.
- **Aurora Serverless v2** for bursty non-prod DBs — bills per ACU-hour, scales to near-zero at idle.
- **Delete old manual snapshots.** Snapshot storage above the free tier is a slow leak.
- **PIT-recovery window** — 7 days in prod is standard; 35 is a compliance-only cost.

## 6. S3 lifecycle

Applied in `modules/s3` for the ALB access-log bucket:
```
30 days  -> STANDARD_IA        (~55 % cheaper)
60 days  -> GLACIER_INSTANT    (~80 % cheaper, ms-retrieval)
90 days  -> expired
noncurrent versions -> 30 days -> deleted
```
Extend the same pattern to any bucket you own. Apply Intelligent-Tiering to buckets with unpredictable access patterns; the analysis fee pays back within a month.

## 7. CloudFront

For any read-heavy or geographically spread traffic:
- Origin-response caching means one origin request per POP per TTL, not per user.
- CloudFront to origin is **free within AWS** for many byte transfers, and you pay much less per GB out to internet than direct-from-ALB.
- Also useful: **CloudFront Functions** for cheap header/URL manipulation at the edge.

## 8. Compute Savings Plans and RIs

Once the baseline is stable:
- **Compute Savings Plans** (Fargate + Lambda + EC2 covered): 1-year no-upfront gets ~40 % off. It's a commitment to $/hour, not to instance types, so you keep flexibility.
- **EC2 Instance Savings Plans** if you run EC2 too: bigger discount, less flexibility.
- **RDS Reserved Instances** for the DB primary and (if applicable) read replicas — 30–60 % off.
- Don't over-commit. Start at ~70 % of measured steady-state usage; buy more as confidence grows.

## 9. Log retention

The default retention on a new CloudWatch log group is "never expire". At 200 k rps that will bankrupt you. In this repo every log group has an explicit `retention_in_days` (see the VPC / ECS / RDS modules) — 14 to 30 days for operational logs, up to 90 for security. Beyond that, ship to S3 (with lifecycle) if compliance requires.

Same rule for VPC Flow Logs — REJECT-only (as configured) is much cheaper than ALL and still catches most operational and security questions.

## 10. Unused / orphaned resources

Regular sweep (monthly, or with **AWS Cost Explorer** anomaly alerts on):
- Unattached EBS volumes (from stopped EC2s).
- Unassociated Elastic IPs (billed per hour when *not* in use).
- Old ECR images (this repo's lifecycle policy handles it: keep last 10 tagged, expire untagged after 7 days).
- Old EBS snapshots / RDS snapshots.
- Unused load balancers and target groups (Terraform state is the source of truth; anything in the console not in state is a candidate for deletion).
- Dev environments left running overnight — biggest silent cost of all.

## 11. Architectural cost decisions in this repo

| Decision | Cost trade-off |
|----------|----------------|
| **Fargate** vs EC2 | Slightly higher per-vCPU-hour; eliminates operator time on OS patching. Net-positive at small fleet size. |
| **Single NAT in dev** | ~$32/mo savings vs per-AZ NAT; costs some AZ-independence for dev only. |
| **Container Insights on** | ~$0.30/task/day; pays for itself the first time you diagnose an incident. |
| **Performance Insights on** | Free for the last 7 days; the ability to see top waits is worth vastly more than the storage cost of PI retention beyond that. |
| **WAF managed rule groups** | ~$1/rule/month + per-request; a single blocked SQL-injection attempt on a database in production dwarfs a year of WAF fees. |
| **Multi-AZ RDS in prod** | ~2 × RDS cost; buys sub-minute failover. Non-negotiable in prod. |
| **AES-256 on ECR / S3** | Free (SSE-S3). Don't second-guess it. |

## 12. What NOT to optimise

- Don't compress logs pre-CloudWatch to save cents — you lose queryability and the savings are trivial.
- Don't switch off Container Insights or Performance Insights to save $10/mo — the next incident costs much more than a year of it.
- Don't downgrade prod to a single AZ to save 50 % — one AZ event undoes years of savings.
- Don't cut ALB access logs — the debugging value is enormous. Just apply lifecycle to keep the S3 bill in check.

The pattern: **spend where you get leverage** (observability, security, reliability), **cut where you get waste** (idle resources, over-provisioning, egress you didn't need).
