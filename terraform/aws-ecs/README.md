# AWS ECS Fargate Terraform module

> **Status: beta.** This module is a working starting point that automation exercises less than the VM appliance, [`cloudformation/aws-vm`](../../cloudformation/aws-vm/). Test it before you rely on it, or use that appliance.

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
                                    │   - 1 task                  │
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
- An identity provider app registration (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `auth_audience`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it.
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

`terraform plan` refuses sign-in settings Broch would refuse at startup: an unknown `auth_provider`, a missing client ID or secret, or a value your provider needs (Auth0 and Okta need `auth_domain`, AzureAd and EntraExternalId need `auth_instance` and `auth_tenant_id`, each unless you set `auth_authority` instead; Oidc needs `auth_authority`; Auth0 also needs `auth_audience`).

**Upgrading a checkout initialised before this module moved to AWS provider 6.x:** run `terraform init -upgrade` instead of `terraform init`, or init fails because your local `.terraform.lock.hcl` still pins the 5.x provider.

## How the secrets flow at runtime

1. You hand the IdP `auth_client_secret` to Terraform as a variable.
2. Terraform writes it (plus the generated master key and DB connection string) to Secrets Manager.
3. The ECS task definition references the secret ARNs — Fargate fetches them at task-start and injects them into the container as env vars (`AUTHENTICATION__CLIENTSECRET`, `BROCH_MASTER_KEY`, `ConnectionStrings__BrochConnection`). Non-secret IdP config (`AUTHENTICATION__PROVIDER`, `CLIENTID`, `ADMINROLES`, …) is passed as plain environment. The license is not a boot input — it's activated in-app on first sign-in. The broch image is public, so no registry credentials are needed.
4. The container never sees the raw secret on disk — it only gets the resolved values via env.

The Postgres password and `BROCH_MASTER_KEY` are *generated* by Terraform (`random_password`), not supplied — they live in Secrets Manager, the container's environment and Terraform state. `BROCH_MASTER_KEY` is the at-rest encryption root the server requires at boot; rotating it forces a one-time re-auth (state self-heals).

Terraform state holds every secret in plaintext; keep it access-controlled (e.g. an encrypted remote backend).

Rotate through Terraform, not the console or `aws secretsmanager update-secret`: Terraform owns these entries, so a direct edit bypasses its state and the next change to the variable overwrites it. For the IdP client secret, set the new `auth_client_secret`, `terraform apply`, then force a new ECS deployment so the task reads it at start:

```sh
aws ecs update-service \
  --cluster broch-cluster \
  --service broch-service \
  --force-new-deployment \
  --region us-east-1
```

The `aws ecs` commands in this README use the default names and region (`name_prefix = "broch"`, `aws_region = "us-east-1"`): cluster `broch-cluster`, service `broch-service`, task-definition family `broch-broch`. Substitute yours if you changed them.

## Tradeoffs / what's deliberately not here

| Decision                       | Why                                                                                  | When to change                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| Single NAT gateway             | Cheaper than per-AZ NATs (~$32/mo each)                                              | When you can't tolerate one AZ outage taking down image pulls   |
| Single-AZ RDS                  | Cheaper, simpler                                                                     | When you need failover (set `multi_az = true` on the resource)  |
| `desired_count = 1`            | Broch runs as one instance and doesn't cluster                                       | Keep it; scale up with `task_cpu` / `task_memory`, then deploy the new revision (see [Pulling a new broch image](#pulling-a-new-broch-image)) |
| No auto-scaling                | Same reason: don't add a task; it would be a second Broch instance on one database   | Keep it                                                         |
| `skip_final_snapshot = true`   | Faster destroy during initial iteration                                              | **Before** going to real production — set to `false`            |
| RDS deletion protection on     | On by default (`rds_deletion_protection`), so a destroy can't delete the database    | Set it to `false` only for an intentional destroy (see Teardown) |
| No WAF                         | Adds complexity + cost                                                               | When you're exposed to abuse and need rate limiting / geo-block |
| No CloudFront                  | Direct ALB is faster for tunnel WebSockets                                           | When you want global edge caching for the API (rarely useful)   |

> **Known gap — database TLS is not authenticated.** The connection string sets no `SSL Mode`, so broch negotiates TLS with RDS (encrypted, since RDS offers it) but never verifies the server's certificate or hostname. Unlike the VM templates (`SSL Mode=VerifyFull` against the Amazon RDS CA bundle), a Fargate task has no host path for the CA bundle yet. See the comment in `database.tf`.

## Pulling a new broch image

The task definition references the image by tag (default: the concrete version this template release pins — not `:latest`). `terraform apply` registers a new task-definition revision but leaves the service on the old one (the service ignores `task_definition` changes), so **`apply` alone does not upgrade**. The same goes for any task-definition change (the image, `task_cpu` / `task_memory`, the `auth_*` sign-in settings other than `auth_client_secret`): after the apply, run the `aws ecs update-service … --task-definition broch-broch` step in Option A. To deploy a new version:

```sh
# Option A: change the tag in tfvars + re-apply, then point the service at the new revision
$EDITOR terraform.tfvars       # set broch_image = "ghcr.io/broch-io/broch:<version>"
terraform apply
aws ecs update-service \
  --cluster broch-cluster \
  --service broch-service \
  --task-definition broch-broch \
  --region us-east-1             # naming the family (no :revision) deploys its latest revision

# Option B: keep the tag, force a fresh pull
aws ecs update-service \
  --cluster broch-cluster \
  --service broch-service \
  --force-new-deployment \
  --region us-east-1
```

The default is already a pinned version so deploys are reproducible; bump it deliberately rather than floating on `:latest`.

## Teardown

RDS deletion protection is on by default, so turn it off first:

```sh
terraform apply -var rds_deletion_protection=false
terraform destroy -var rds_deletion_protection=false
```

Note: `skip_final_snapshot = true` means the Postgres data is deleted permanently. If you want to keep it, set that to `false` first and re-apply before destroying.
