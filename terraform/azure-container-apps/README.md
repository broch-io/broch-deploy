# Azure Container Apps Terraform module

Production-shape Broch on Azure: Container Apps for the server, Postgres Flexible Server for state, Key Vault for secrets, Log Analytics for logs. Mirrors the architecture our own central server runs on.

## What this provisions

```
                                    ┌────────────────────────────────┐
internet  ─── HTTPS:443  ─────▶     │ Container App ingress          │
                                    │   - HTTPS, auto-transport      │
                                    │   - custom domain binding      │
                                    └──────────────┬─────────────────┘
                                                   │ HTTP:8080
                                    ┌──────────────▼─────────────────┐
                                    │ Container App                  │
                                    │   - broch image (GHCR)         │
                                    │   - user-assigned identity     │
                                    │   - liveness + readiness probe │
                                    │   - min=1, max=1 (configurable)│
                                    └──────────────┬─────────────────┘
                                                   │ TCP:5432 (SSL)
                                    ┌──────────────▼─────────────────┐
                                    │ Postgres Flexible Server       │
                                    │   - B_Standard_B1ms (default)  │
                                    │   - public-access mode         │
                                    │     w/ Azure-services firewall │
                                    └────────────────────────────────┘

                                    ┌────────────────────────────────┐
                                    │ Key Vault                      │
                                    │   - broch-license              │
                                    │   - github-pat                 │
                                    │   - postgres-connection-string │
                                    │   - RBAC: identity is reader   │
                                    └────────────────────────────────┘
```

## What it costs

Rough monthly numbers, `eastus`, pay-as-you-go pricing as of 2026:

| Resource                              | ~Monthly cost (USD) |
| ------------------------------------- | ------------------- |
| Container Apps (0.5 vCPU / 1 Gi, 1×)  | $15-25              |
| Postgres Flexible B_Standard_B1ms     | $13-15              |
| Log Analytics workspace + ingestion   | $3-10               |
| Key Vault (4 secrets, low ops)        | $0.30               |
| **Total baseline**                    | **~$30-50/month**   |

Notably cheaper than the AWS equivalent — Container Apps doesn't bill for the equivalent of a NAT gateway / ALB.

## Prerequisites

- Terraform 1.6+
- Azure CLI logged in (`az login`) with a subscription that has the right resource providers registered. The first apply will register them if needed but it takes 5-10 minutes.
- Either Owner or Contributor + User Access Administrator on the target subscription (you need to assign Key Vault RBAC roles).
- DNS control for your wildcard hostname's parent domain. Container Apps doesn't manage DNS for you — you create records by hand or via your DNS provider's Terraform module.
- A Broch license key.
- A GitHub PAT with `read:packages`.

## Setup

```sh
# 1. Authenticate
az login
az account set --subscription <subscription-id>

# 2. Fill in tfvars
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 3. Apply
terraform init
terraform plan
terraform apply
```

That gets the Container App running, but the **custom-domain binding requires a separate manual step** because Azure needs you to prove DNS control before it'll bind the cert.

## Binding the custom domain (one-time, post-apply)

After the first `terraform apply` completes:

```sh
# 1. Get the verification ID + the app's default hostname
VERIF_ID=$(terraform output -raw container_app_verification_id)
APP_FQDN=$(terraform output -raw container_app_fqdn)
HOSTNAME=$(terraform output -raw broch_url | sed 's|https://||')

# 2. Add these DNS records in your provider:
#      A     <hostname>           → IP of $APP_FQDN
#      TXT   asuid.<hostname>     → $VERIF_ID
#    (Container Apps requires the TXT record to validate ownership.)

# 3. Bind the custom domain + provision an Azure-managed cert
az containerapp hostname bind \
  --hostname "$HOSTNAME" \
  --resource-group broch-rg \
  --name broch-app \
  --validation-method CNAME

# Re-run as needed if cert provisioning hasn't propagated yet (~5-10 min).
```

**Wildcard cert is a separate problem.** Azure Container Apps' built-in managed certs **don't issue wildcards**. For tunnel subdomains (`*.tunnels.example.com`), you have three options:

1. **Front Door / Application Gateway with a managed wildcard** in front of Container Apps. Adds ~$35/mo for Front Door but is the cleanest production answer.
2. **Provision a wildcard cert separately** (Let's Encrypt via certbot+DNS, or commercial CA) and upload it via `az containerapp env certificate upload` + `az containerapp hostname bind`.
3. **Skip wildcards** entirely if your deployment doesn't use tunnel subdomains.

The README at the repo root flags this as the main Azure-vs-AWS tradeoff: AWS gets wildcard certs in-stack via ACM, Azure makes you do extra work.

## How secrets flow at runtime

1. Variables → Key Vault on `terraform apply` (writer role: the human running TF)
2. Container App's user-assigned identity has the Key Vault Secrets User role
3. Container App `secret { }` blocks reference each Key Vault entry by URI
4. Container `env { secret_name = ... }` blocks map secrets into env vars (`BROCH_LICENSE`, `ConnectionStrings__DefaultConnection`)
5. GHCR pull credential comes from the same path — `registry.password_secret_name`

Rotate by editing the Key Vault secret, then issuing a Container Apps revision restart (`az containerapp revision restart --name broch-app --resource-group broch-rg --revision <name>`).

## Tradeoffs / what's deliberately not here

| Decision                       | Why                                             | When to change                                       |
| ------------------------------ | ----------------------------------------------- | ---------------------------------------------------- |
| Public-access Postgres         | Avoids VNet integration setup                   | When compliance / security demands private network   |
| `AllowAzureServices` FW rule   | Container Apps egress IPs aren't static         | When you VNet-integrate (then drop this rule)        |
| `min=1, max=1`                 | Predictable cost; broch handles steady traffic  | When you need HA or scale-out                        |
| No zone redundancy on Postgres | Cheapest tier                                   | When you need HA                                     |
| Single Container App revision  | Simpler initial deploy                          | When you want canary / blue-green via traffic_weight |
| No Front Door                  | Wildcard cert problem documented; FD adds cost  | When you're past the proof-of-concept phase          |
| `purge_protection_enabled=false` on KV | Faster destroy during iteration         | **Before** going to real production                  |

## Pulling a new broch image

Update the tag and re-apply:

```sh
$EDITOR terraform.tfvars       # set broch_image = "ghcr.io/broch-io/broch:1.6.0"
terraform apply
```

Container Apps will roll out a new revision with the new image; the old revision drains based on the ingress traffic-weight config.

## Teardown

```sh
terraform destroy
```

Key Vault soft-delete means the vault sticks around in a deleted state for 7 days. If you want to re-apply with the same name immediately, either change `name_prefix` or purge the soft-deleted vault: `az keyvault purge --name <vault-name>` (needs the `Key Vault Contributor` role).
