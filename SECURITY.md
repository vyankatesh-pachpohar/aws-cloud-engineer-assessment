# SECURITY.md — Security posture

Security in this repo is layered: network, identity, data, application, image, delivery. Any one layer alone isn't enough; together they narrow the blast radius of any single failure.

## 1. Network isolation

**Public/private split.**
- Public subnets host only the ALB and NAT gateway. They have `0.0.0.0/0` via the IGW.
- Private subnets host ECS tasks and RDS. They reach the internet only outbound via NAT, never inbound from it.
- ECS tasks have **no public IP** (`assign_public_ip = false` on the service network configuration).

**Security groups (SG-to-SG, not CIDR).**
- ALB SG: `0.0.0.0/0:80` (redirect) and `0.0.0.0/0:443` (from users).
- ECS tasks SG: `:8000` **only from the ALB SG**. Nothing else on the internet or in the VPC can reach tasks.
- RDS SG: `:5432` **only from the ECS tasks SG**. Nothing else — no bastion, no jumphost — can even open a TCP connection to Postgres.

Because SGs reference *each other by SG ID*, adding a task or scaling the fleet automatically inherits the RDS ingress rule. There's no CIDR to maintain, no drift.

### "How do you prevent public internet access to the DB?" (assessment ask)

Four independent barriers:
1. RDS instance is in **private subnets** with no route to the IGW.
2. `publicly_accessible = false` on the RDS instance.
3. RDS SG allows `:5432` **only from the ECS tasks SG** — even inside the VPC, only tasks can reach it.
4. The parameter group forces `rds.force_ssl = 1`, so even a successful TCP connection must complete a TLS handshake to be usable.

Breaking DB access requires breaching *all four*.

## 2. Identity & IAM (least privilege)

- **Two IAM roles per ECS service** (see `modules/ecs`):
  - `execution` role — used by the ECS agent *before* the container starts, to pull the image from ECR, read the DB password from Secrets Manager, and send logs to CloudWatch.
  - `task` role — assumed by the *running* container for its own AWS SDK calls. Empty by default; the app only talks to RDS.
- Secrets read is scoped to **the exact secret ARN**, not `*`. KMS `Decrypt` is scoped with the `kms:ViaService = secretsmanager.<region>.amazonaws.com` condition.
- **No IAM user access keys anywhere.** CI/CD authenticates via **OIDC** federation (`modules/iam-github-oidc`): GitHub Actions gets a short-lived JWT, exchanges it via `sts:AssumeRoleWithWebIdentity`, and receives 1-hour temporary credentials. The role trust policy is **repo- and ref-scoped**:
  ```
  token.actions.githubusercontent.com:sub = repo:<org>/<repo>:ref/heads/main
                                                             environment:dev
                                                             environment:prod
  ```
  A fork or a different branch cannot assume the role even if it steals a workflow.
- The deploy role has a **least-privilege inline policy**: only the ECR / ECS actions needed to publish an image and roll a service, and PassRole restricted to the ECS task/execution roles with a `PassedToService=ecs-tasks.amazonaws.com` condition.

## 3. Credentials & secrets management

### "How do you protect DB credentials?" (assessment ask)

- The DB password is generated inside Terraform (`random_password`, 32 chars) and stored in **AWS Secrets Manager**.
- The RDS module receives the password as a `sensitive = true` variable. Even `terraform output` marks it sensitive.
- The ECS task definition references the secret by **ARN** in the `secrets = [...]` array; the ECS agent injects it as an environment variable **at container start**. It never appears in the task-def JSON.
- The application reads it from `DB_PASSWORD` and marks the field `repr=False` in Pydantic so it never appears in a `repr()` / log line.
- Terraform state itself has secret values, so state lives in an **encrypted, versioned, private S3 bucket** with public-access-block on. Access to state is IAM-controlled.
- Secret rotation is possible via Secrets Manager rotation Lambda + `secretsmanager:UpdateSecret`; the app just needs the task restarted (rolling deploy) to pick up the new value. Adding auto-rotation is one Terraform block away.

## 4. Data protection

**At rest:**
- RDS storage: KMS-encrypted (`storage_encrypted = true`, default `aws/rds` key, upgradable to CMK).
- ECR images: AES-256 at rest.
- S3 buckets (ALB logs, state): server-side encryption, versioning on, public access blocked at the bucket level.
- Secrets Manager: KMS-encrypted by default.

**In transit:**
- Client → ALB: HTTPS 443 with TLS 1.2/1.3 policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (when an ACM cert is supplied). HTTP 80 → 301 to HTTPS.
- ALB → ECS: HTTP within the VPC (encrypted at hypervisor level in the AZ). For end-to-end TLS a self-signed cert + `HTTPS` target group can be added.
- App → RDS: TLS enforced by parameter group (`rds.force_ssl = 1`).

## 5. Web application firewall

`modules/waf` attaches WAFv2 to the ALB with:
- **AWSManagedRulesCommonRuleSet** — OWASP Top 10 basics (XSS, LFI, request smuggling).
- **AWSManagedRulesKnownBadInputsRuleSet** — targeted exploits, path traversal.
- **AWSManagedRulesSQLiRuleSet** — SQL injection patterns.
- **Rate-limit** — 2000 requests per 5 min per source IP (env-tunable). Blocks credential-stuffing and low-effort scraping before the request touches ECS.

## 6. Container & image security

- Multi-stage Dockerfile: compilers stay in the builder, runtime image is minimal (`python:3.12-slim`).
- Runs as **non-root** user `app` with `nologin` shell.
- **Trivy scan** on every CI build (`aquasecurity/trivy-action`) with `HIGH,CRITICAL` failing the pipeline for both image and filesystem (dependencies).
- ECR `scan_on_push = true` re-scans in the registry.
- ECR lifecycle policy purges untagged images after 7 days and keeps only the 10 most recent tagged images — smaller attack surface, lower cost.
- Image tagging is **mutable in dev, immutable in prod** (change one variable).

## 7. Logging, auditing, detection

- **VPC Flow Logs** (REJECT traffic) → CloudWatch. Shows scanning and denied traffic without the noise of ACCEPT.
- **ALB access logs** → S3 with lifecycle to Glacier. Full request record for forensics.
- **CloudWatch Logs** for the app (structured JSON, request-id, order-id) → queryable with Logs Insights.
- **CloudTrail** is on by default per account (recommended: management + data events, with a dedicated logging account and log-file integrity validation). Beyond the scope of a single-app repo but noted here.
- **CloudWatch alarms** on 5xx, latency, unhealthy hosts, RDS conn/storage/CPU → SNS email. `modules/monitoring`.

## 8. Delivery pipeline security

- OIDC only (see §2).
- Terraform state in S3 with SSE + versioning + public-access-block; state locking in DynamoDB (concurrent applies fail rather than corrupt state).
- `terraform fmt -check` + `terraform validate` + PR-based `terraform plan` — no `apply` on unreviewed changes.
- CI runs on the same code the deploy job uses; the image tag = the git commit SHA, so the deployed artifact is traceable to a specific commit.
- No secrets in workflow files; only `vars.*` and OIDC.

## 9. Threat model (short)

| Threat | Mitigation |
|--------|-----------|
| Attacker on the internet reaches RDS | Private subnets, SG-to-SG, no public IP, TLS enforced |
| Leaked DB password | Rotate in Secrets Manager, rolling deploy picks up new value |
| Stolen GitHub PAT | We don't use PATs; OIDC scoped to repo+branch |
| Compromised container image | Trivy CI fails on HIGH/CRITICAL; ECR scan-on-push; small base image |
| SQL injection | Parameterised queries via SQLAlchemy + WAF SQLi rule set |
| Retry storms / abusive clients | WAF rate limit; app `Retry-After` header on 503 |
| Insider mistake (broad IAM) | Least-privilege roles, PassRole scoped, no `*` on write actions |
| State-file leak | S3 SSE + versioning + public-access-block + IAM-only access |

## 10. Known gaps to close in prod

- Add an ACM certificate + custom domain (HTTPS on ALB is code-ready — set `acm_certificate_arn`).
- End-to-end TLS from ALB to task (requires app cert or self-signed).
- Enable **AWS GuardDuty** and **AWS Config** at the account level (out-of-repo; account-wide).
- Auto-rotation on the Secrets Manager secret.
- Split the deployer IAM role into a plan-only (read) role for PRs and an apply role for main.
- Replace the single NAT with per-AZ NAT in prod (already a variable).
- Turn on RDS `IAM authentication` for read-only ad-hoc access (no shared password for humans).
