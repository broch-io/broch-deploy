# AWS ECS Fargate Terraform module

> **Status: experimental.** AWS isn't part of Broch's current supported deploy set. This module is a working starting point, not a supported production path — expect rough edges and validate thoroughly before relying on it. The docker-compose and Azure/DigitalOcean examples are the supported options today.

Production-shape Broch on AWS: ECS Fargate behind an Application Load Balancer, RDS Postgres in private subnets, secrets in Secrets Manager, TLS via an ACM cert covering both the apex and wildcard hostname.

## What this provisions

```
                                    ┌─────────────────────────────┐
internet  ─── HTTPS:443  ─────▶     │ Application Load Balancer   │
                                    │   - ACM cert (apex + wild)  │
                                    │   - HTTP→HTTPS redirect     │
                                    └──────────────┬──────────────┘
                                                   │ HTTP:8080
                                    ┌──────────────▼──────────────┐
                                    │ ECS Fargate service         │
                                    │   - broch image (GHCR)      │
                                    │   - awsvpc / private subnet │
                                    │   - 1 task, configurable    │
                                    └──────────────┬──────────────┘
                                                   │ TCP:5432
                                    ┌──────────────▼──────────────┐
                                    │ RDS Postgres 17             │
                                    │   - db.t4g.micro (default)  │
                                    │   - single-AZ               │
                                    │   - encrypted at rest       │
                                    └─────────────────────────────┘
```

Tightly-scoped IAM lets the task read its own secrets — nothing more. The broch image pulls from GHCR without credentials (public image).

## Prerequisites

- Terraform 1.6+
- AWS credentials with permissions to create everything in this module (VPC, ECS, RDS, ALB, Route 53, ACM, IAM, Secrets Manager). Easiest: an admin role for the initial apply, then restrict ongoing.
- A Route 53 hosted zone for your wildcard hostname's parent domain. You provide the zone ID; this module adds records to it.
- An identity provider app registration (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Setup

```sh
# 1. Copy + fill the tfvars template
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Initialise providers
terraform init

# 3. Review the plan (lots of resources first time — 30+)
terraform plan

# 4. Apply (5-10 min on first run; RDS provisioning is the long pole)
terraform apply

# 5. Get the URL and verify
echo "Broch is at: $(terraform output -raw broch_url)"
curl -fsS "$(terraform output -raw broch_url)/healthz"
```

## How the secrets flow at runtime

1. You hand the IdP `auth_client_secret` to Terraform as a variable.
2. Terraform writes it (plus the generated master key and DB connection string) to Secrets Manager.
3. The ECS task definition references the secret ARNs — Fargate fetches them at task-start and injects them into the container as env vars (`AUTHENTICATION__CLIENTSECRET`, `BROCH_MASTER_KEY`, `ConnectionStrings__BrochConnection`). Non-secret IdP config (`AUTHENTICATION__PROVIDER`, `CLIENTID`, `ADMINROLES`, …) is passed as plain environment. The license is not a boot input — it's activated in-app on first sign-in. The broch image is public, so no registry credentials are needed.
4. The container never sees the raw secret on disk — it only gets the resolved values via env.

The Postgres password and `BROCH_MASTER_KEY` are *generated* by Terraform (`random_password`), not supplied — they exist only in Secrets Manager and the container's environment. `BROCH_MASTER_KEY` is the at-rest encryption root the server requires at boot; rotating it forces a one-time re-auth (state self-heals).

Rotating any secret = edit the secret value (via console or `aws secretsmanager update-secret`) + force a new ECS deployment (`aws ecs update-service --force-new-deployment`).

## Tradeoffs / what's deliberately not here

| Decision                       | Why                                                                                  | When to change                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| Single NAT gateway             | Cheaper than per-AZ NATs (~$32/mo each)                                              | When you can't tolerate one AZ outage taking down image pulls   |
| Single-AZ RDS                  | Cheaper, simpler                                                                     | When you need failover (set `multi_az = true` on the resource)  |
| `desired_count = 1`            | Broch state is in Postgres; one task is sufficient for low/medium traffic            | When you need zero-downtime deploys or higher throughput        |
| No auto-scaling                | Avoid surprise bill from runaway scale-out; broch's workload is usually steady-state | When tunnel volume becomes spiky                                |
| `skip_final_snapshot = true`   | Faster destroy during initial iteration                                              | **Before** going to real production — set to `false`            |
| `deletion_protection = false`  | Same as above                                                                        | **Before** going to real production — set to `true`             |
| No WAF                         | Adds complexity + cost                                                               | When you're exposed to abuse and need rate limiting / geo-block |
| No CloudFront                  | Direct ALB is faster for tunnel WebSockets                                           | When you want global edge caching for the API (rarely useful)   |

## Pulling a new broch image

The task definition references the image by tag (default: a concrete pinned version, e.g. `:1.26.0` — not `:latest`). To deploy a new version:

```sh
# Option A: change the tag in tfvars + re-apply
$EDITOR terraform.tfvars       # set broch_image = "ghcr.io/broch-io/broch:1.6.0"
terraform apply

# Option B: keep the tag, force a fresh pull
aws ecs update-service \
  --cluster broch-cluster \
  --service broch-service \
  --force-new-deployment \
  --region us-east-1
```

The default is already a pinned version so deploys are reproducible; bump it deliberately rather than floating on `:latest`.

## Teardown

```sh
terraform destroy
```

Note: `skip_final_snapshot = true` means the Postgres data is deleted permanently. If you want to keep it, set that to `false` first and re-apply before destroying.
