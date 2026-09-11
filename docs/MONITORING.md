# MONITORING.md — Observability

Applies to `modules/monitoring` and how the app instruments itself.

## Metrics (CloudWatch)

Automatically collected:
- **ALB**: `RequestCount`, `HTTPCode_ELB_*`, `HTTPCode_Target_*`, `TargetResponseTime` (percentiles), `UnHealthyHostCount`, `HealthyHostCount`.
- **ECS Container Insights**: per-service `CPUUtilization`, `MemoryUtilization`, `RunningTaskCount`.
- **RDS**: `DatabaseConnections`, `CPUUtilization`, `FreeStorageSpace`, `ReadLatency`, `WriteLatency`, `Deadlocks`.
- **WAF**: `AllowedRequests`, `BlockedRequests`, per-rule counters.

## Alarms → SNS email

Configured in `modules/monitoring`:
| # | Alarm | Threshold | Why |
|---|-------|-----------|-----|
| 1 | ALB 5xx count | > 10 / min × 2 min | user-visible failures |
| 2 | ALB unhealthy hosts | ≥ 1 / 3 min | capacity below quorum |
| 3 | ALB p95 latency | > 1 s / 5 min | SLO breach |
| 4 | ECS CPU | > 85 % / 10 min | under-provisioned or runaway |
| 5 | RDS connections | > 80 / 5 min | pool leak / traffic spike |
| 6 | RDS free storage | < 2 GB / 10 min | silent outage risk |
| 7 | RDS CPU | > 85 % / 10 min | query problem / needs upsize |

Actions: `alarm_actions = SNS` (email), `ok_actions = SNS` on the 5xx alarm so ack + recovery both notify.

## Dashboard

`aws_cloudwatch_dashboard` with 4 widgets: ALB requests+5xx, ALB latency percentiles, ECS CPU+memory, RDS connections+CPU. Bookmark it for on-call.

## Logs

- **Application** — JSON lines to `/aws/ecs/<service>`. Every line has `request_id`; order operations include `order_id`.
- **ALB access logs** — S3 with lifecycle (see `modules/s3`).
- **VPC Flow Logs** — REJECT only, `/aws/vpc/<name>/flowlogs`.
- **RDS logs** — `postgresql` and `upgrade` exported to CloudWatch.

## Recommended Logs Insights queries

Errors right now:
```
fields @timestamp, request_id, level, message, status
| filter status >= 500 or level = "ERROR"
| sort @timestamp desc | limit 100
```

Top error messages this hour:
```
fields @message
| filter level = "ERROR"
| stats count(*) as n by message
| sort n desc | limit 5
```

p95 request duration by path (using access logs from the ALB in Athena; app logs don't record duration here — add if needed):
```
SELECT request_url, approx_percentile(target_processing_time, 0.95) AS p95
FROM alb_access_logs
WHERE dt = date '2026-09-11'
GROUP BY 1 ORDER BY p95 DESC LIMIT 20;
```

## Traces (recommended next step)

Not enabled in this repo. To add:
- Instrument FastAPI with `opentelemetry-instrumentation-fastapi` + OTLP exporter.
- Sidecar / ADOT collector in the task to ship to AWS X-Ray or an OTel backend.
- Request-id middleware is already in place — traces will inherit it as the parent span attribute.

## Alerting hygiene

- Every alarm has an OK action so recovery is announced.
- No alarm on averages that hides tails — use percentiles for latency.
- `treat_missing_data = "notBreaching"` where appropriate so a missing metric window doesn't trigger the pager.
- Every alarm names a runbook (add `alarm_description` links to a wiki in real deployment).

## Business metrics

Beyond infra:
- Orders/min by SKU.
- 5xx per 1000 orders (SLO ratio, not raw count).
- Idempotency-Key replay rate — if too high, clients are retrying too eagerly.

Emit them from the app as CloudWatch EMF records (single-line JSON with `_aws.CloudWatchMetrics`) so they end up as first-class metrics with dimensions, no PutMetricData calls, no throttling.
