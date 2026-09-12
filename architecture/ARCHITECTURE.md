# Architecture

## 1. Target architecture (this repo)

> **What's deployed today:** Users hit the ALB's AWS-assigned DNS name directly (`order-api-dev-alb-<id>.ap-south-1.elb.amazonaws.com`), no Route 53, no custom domain, HTTP not HTTPS. Route 53 + ACM certificate are optional additions that plug in when a real domain is available (see §2.9 "What stays optional"). The core compute, data, security, and delivery pattern is complete without them.

```
              Users
                |  HTTP (dev)  /  HTTPS 443 (with ACM cert)
                v
        [Route 53]  <-- optional, needs a domain; not deployed today
                |
                v
              WAFv2
       (managed rules + rate limit)
                |
                v
      Application Load Balancer   <-- public subnets, 2 AZs
       target group -> IPs (awsvpc)
                |  access logs -> S3
                |  HTTP 8000 (TG health = /health)
              ┌────────────┴────────────┐
              │                         │
      ┌───────▼──────┐          ┌───────▼──────┐   ECS Fargate tasks
      │  Task (AZ-a) │  ...     │  Task (AZ-b) │   private subnets
      │  FastAPI     │          │  FastAPI     │   auto-scaled 2–10
      │  uvicorn x2  │          │  uvicorn x2  │
      └───────┬──────┘          └──────┬───────┘
              │                        │
              │        awsvpc + tasks-SG
              │                        │
              ▼                        ▼
        ┌──────────────────────────────────┐
        │  RDS PostgreSQL 16 (private)     │  Multi-AZ in prod
        │  SG: 5432 only from tasks-SG     │  encrypted, PIT recovery
        └──────────────────────────────────┘
                       ▲
                       │
                Secrets Manager
                (DB password)          NAT GW: egress for ECR, Secrets, S3
                                       CloudWatch Logs: /aws/ecs/<name>
                                       CloudWatch Alarms -> SNS (email)
                                       VPC Flow Logs (REJECT) -> CW Logs
                                       S3: ALB access logs (lifecycle IA→Glacier)
```

Static SVG version: [architecture-diagram.svg](architecture-diagram.svg)

## 2. Design decisions (assessment §3 answers)

### 2.1 Why ECS Fargate (not EC2)
- **No OS to patch.** With EC2 I'd own AMIs, kernel upgrades, SSM Session Manager, and Auto Scaling Group lifecycle. Fargate removes that whole layer for a per-second premium that's dwarfed by the operator time saved at this scale (a handful of small services).
- **Per-second billing + right-sized tasks.** For an ordering API with spiky traffic, right-sizing at the *task* level (0.5 vCPU / 1 GB) is more granular than picking an EC2 instance class.
- **Same container ships everywhere.** The image built by CI runs unchanged locally (`docker compose up`), in CI (Trivy scan target), and on Fargate. No AMI baking step.
- **EC2 would win when:** you need GPU / high‑memory tiers Fargate lacks, you have >~50 tasks per node so the Fargate premium bites, or you already own an ECS-on-EC2 cluster with capacity headroom. None applies here.

### 2.2 High availability
- **VPC:** 2 AZs (extendable to 3 with `az_count = 3`). ALB requires ≥ 2 AZs.
- **ALB:** managed by AWS across the AZs.
- **ECS service:** `min_capacity = 2`, tasks scheduled across AZs by default. `deployment_minimum_healthy_percent = 100` and `deployment_maximum_percent = 200` give a genuine zero-downtime rolling deploy.
- **RDS:** `multi_az = true` in prod (synchronous standby in the second AZ, sub-minute automatic failover).
- **NAT:** single NAT in dev to save cost; `nat_per_az = true` in prod so losing an AZ doesn't blackhole egress.
- **Deployment safety:** ECS deployment circuit breaker with `rollback = true` — a bad rollout automatically reverts to the last-good task definition.

### 2.3 Traffic distribution
- **When Route 53 is enabled** (has a domain): Route 53 alias -> ALB -> cross-zone load balancing (default on) -> target group (IP targets, Fargate ENIs) -> healthy tasks only. Health = TG probe on `/health` (200 vs 503, not just port-open). **In this deployment** users hit the ALB's AWS-assigned DNS name directly; wiring a custom domain is a variable flip (`acm_certificate_arn`) plus a small Route 53 module.

### 2.4 Scaling
Two target-tracking policies on the ECS service:
- **CPU 60 %** (predefined `ECSServiceAverageCPUUtilization`) — protects the app.
- **~200 req/target** (predefined `ALBRequestCountPerTarget`) — protects RDS from stampedes because we scale on *arriving load*, not just symptoms.
- Cooldowns are asymmetric: **scale-out 60 s, scale-in 300 s** — add capacity fast, shed it slowly (avoids flapping under bursty traffic).
- RDS scales vertically (instance class) and with **read replicas** for read-heavy paths. Storage auto-scales up to `max_allocated_storage`.

### 2.5 Database security
- Private subnets, no public IP.
- SG rule: 5432 from **the ECS tasks SG only** (SG-to-SG, not a CIDR).
- Encryption at rest (KMS), TLS in transit enforced via parameter group (`rds.force_ssl = 1`).
- Password generated by Terraform, stored in Secrets Manager, injected into the task at start-up. Never in state as plaintext env, never in the image, never committed.
- Automatic backups + Point-in-Time Recovery, deletion protection + final snapshot in prod.

### 2.6 Failure handling
| Layer | Failure | What happens |
|------|---------|---------------|
| App code | uncaught exception | 500 JSON, request-id logged |
| DB conn | pool timeout / dropped | `OperationalError` → 503 + `Retry-After` → ALB retries |
| Task | health check fails | TG deregisters after 3 fails × 15 s, ECS replaces |
| Deploy | bad image | ECS circuit breaker rolls back |
| AZ | outage | ALB routes to healthy AZ; RDS fails over (Multi-AZ) |
| RDS | primary down | Automatic failover; `pool_pre_ping` reconnects on next query |

### 2.7 Growth headroom
| Component | Now (5k users) | 50k users |
|-----------|----------------|-----------|
| ECS tasks | 2 | 10–30 (raise `max_capacity`) |
| RDS | db.t3.micro | db.r6g.large + 1–2 read replicas |
| Cache | none | ElastiCache Redis (order-by-id cache; hot inventory) |
| Queue | none | SQS between API and slow work (email, fulfilment) |
| Edge | direct to ALB | CloudFront in front of ALB; S3+CloudFront for static |

Details in [SCALABILITY.md](../SCALABILITY.md).

### 2.8 What stays serverless — and why
- **Amazon S3** for ALB access logs, image assets, backups — object storage should never be run on servers.
- **AWS Lambda** for out-of-band async workers (nightly report, webhook receiver) where request rate is spiky and unit-of-work is small. The sync request path leaves Lambda because we now have predictable connection pooling, warm containers, and simpler local dev.
- **SNS/SQS** for pub/sub and durable queues — self-managed brokers don't add value here.
- **Secrets Manager, CloudWatch, WAF, Route 53, ACM** — all managed; running any of these on servers would be a step backwards.

## 3. Environments
Structure: `terraform/environments/dev/` (and `prod/` created by copy-editing `main.tf` values). Modules are shared, values differ.

| Setting | dev | prod |
|---------|-----|------|
| `nat_per_az` | false (1 NAT) | true (1 NAT/AZ) |
| RDS `multi_az` | false | true |
| RDS class | db.t3.micro | db.r6g.large (or bigger) |
| Backup retention | 1 day | 7–35 days |
| Deletion protection | off | on |
| ECS min/max | 2 / 6 | 4 / 30 |
| WAF rate limit | 2000/5 min/IP | env-tuned |
| ALB deletion protection | off | on |
| ACM cert | optional | required |
