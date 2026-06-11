# Azure Container Apps — Bicep template

Broch on Azure Container Apps, deployed with Bicep. **This is the same template Broch, LLC runs for its own dev and production deployments** — what you deploy here is what we run.

By default it's a self-contained single-replica stack: the Broch server plus a PostgreSQL sidecar, with the database persisted to Azure Files. No Key Vault, no separate managed database — fewer moving parts and lower cost than the [Terraform Azure module](../../terraform/azure-container-apps/), which provisions Postgres Flexible Server + Key Vault for a scale-out, production-HA shape. Pick this one if you want the smallest Azure footprint or want to match exactly what Broch runs; pick the Terraform module if you need managed Postgres and horizontal scale.

## What this provisions

```
                                    ┌────────────────────────────────┐
internet  ─── HTTPS:443  ─────▶     │ Container App ingress          │
                                    │   - external, allowInsecure=off│
                                    │   - custom-domain + wildcard   │
                                    │     binding (BYO PFX cert)     │
                                    └──────────────┬─────────────────┘
                                                   │ HTTP:8080
                                    ┌──────────────▼─────────────────┐
                                    │ Container App (single replica) │
                                    │   - broch container (GHCR)     │
                                    │   - postgres:16 sidecar        │  ◀── Embedded mode
                                    │   - secrets inline in config   │
                                    └──────────────┬─────────────────┘
                                                   │ volume mount
                                    ┌──────────────▼─────────────────┐
                                    │ Azure Files share              │
                                    │   - PostgreSQL data (5 GiB)    │
                                    └────────────────────────────────┘

  Shared mode: drop the sidecar + Azure Files, set databaseMode=Shared and
  point databaseConnectionString at your own managed Postgres instead.

  Optional: Log Analytics + Application Insights are created when
  telemetryProvider=ApplicationInsights and no connection string is supplied.
```

## What it costs

Rough monthly numbers, `eastus`, pay-as-you-go, Embedded mode:

| Resource                                   | ~Monthly cost (USD) |
| ------------------------------------------ | ------------------- |
| Container Apps (broch 0.5 vCPU / 1 GiB + postgres 0.25 / 0.5, always-on 1×) | $35-50 |
| Azure Files (5 GiB, transactions)          | $1-3                |
| Log Analytics + App Insights (if enabled)  | $3-10               |
| **Total baseline**                         | **~$40-60/month**   |

Shared mode removes the sidecar but you then pay for your own managed Postgres separately.

## Prerequisites

- Azure CLI logged in (`az login`) against a subscription with the Container Apps resource providers registered (the first deploy registers them; takes 5-10 min).
- Contributor on the target resource group.
- DNS control for your wildcard hostname's parent domain — Container Apps doesn't manage DNS for you.
- An identity provider app registration (Auth0, Entra ID / Azure AD, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Setup

```sh
# 1. Authenticate
az login
az account set --subscription <subscription-id>

# 2. Resource group
az group create --name broch-rg --location eastus

# 3. Fill in parameters
cp parameters.example.bicepparam parameters.bicepparam
$EDITOR parameters.bicepparam   # gitignored — holds masterKey, DB password, client secret

# 4. Deploy
az deployment group create \
  --resource-group broch-rg \
  --template-file mainTemplate.bicep \
  --parameters parameters.bicepparam
```

The deployment outputs `brochUrl` (the default `*.azurecontainerapps.io` URL), `sshEndpoint`, and the resolved database/monitoring info.

> **The master key is yours to keep.** `masterKey` is the at-rest encryption root — Broch, LLC never sees it. Generate it with `openssl rand -base64 48`, store it in your own secret store, and supply the same value on every redeploy. Rotating it invalidates anything DataProtection-wrapped in the database (refresh tokens, persisted license, usage blob).

## Custom domain + wildcard TLS

Broch issues tunnels on `*.<wildcardHostname>`, so you need the base host **and** its wildcard bound. Unlike the Terraform module — where Azure's managed certs can't issue wildcards — this template binds a **wildcard cert you supply** as a base64 PFX:

```sh
# Convert your wildcard PFX to base64 and pass it in:
#   sslCertificatePfxBase64 = "$(base64 -w0 wildcard.pfx)"
#   sslCertificatePassword  = "<pfx-password>"
#   customDomainHostname         = "tunnels.example.com"
#   customDomainWildcardHostname = "*.tunnels.example.com"
```

Before the binding validates, Azure needs to prove you control the domain:

```sh
# Get the verification ID and the app's default hostname
APP_FQDN=$(az containerapp show -g broch-rg -n <siteName> --query properties.configuration.ingress.fqdn -o tsv)
VERIF_ID=$(az containerapp env show -g broch-rg -n <siteName>-env --query properties.customDomainConfiguration.customDomainVerificationId -o tsv)

# Add DNS records at your provider:
#   A     tunnels.example.com        → IP of $APP_FQDN
#   TXT   asuid.tunnels.example.com  → $VERIF_ID
#   A/CNAME for the wildcard *.tunnels.example.com → same target
```

Re-run the deploy once DNS has propagated and the cert/binding will complete.

## How secrets flow at runtime

This template keeps secrets **inline in the Container App configuration** (the `secrets` block), referenced from env via `secretRef` — there's no Key Vault. The values are written once at deploy time from your parameters:

- `master-key` → `BROCH_MASTER_KEY`
- `db-connection` → `ConnectionStrings__DefaultConnection`
- `postgres-password` → the sidecar's `POSTGRES_PASSWORD` (Embedded mode)
- `auth-client-secret` → `AUTHENTICATION__CLIENTSECRET`

Rotate by re-running the deploy with the new value, or `az containerapp secret set` followed by a revision restart. If you want Key Vault-backed secrets and managed Postgres, use the [Terraform module](../../terraform/azure-container-apps/) instead.

## Tradeoffs / what's deliberately not here

| Decision                          | Why                                                  | When to change                                      |
| --------------------------------- | ---------------------------------------------------- | --------------------------------------------------- |
| Embedded Postgres sidecar         | Self-contained, cheapest, matches what Broch runs    | Set `databaseMode=Shared` for managed/HA Postgres   |
| Single replica (Embedded)         | Sidecar Postgres is single-instance; no scale-out    | Use Shared mode + raise `maxReplicas`               |
| Secrets inline, no Key Vault      | One fewer resource + role assignment to manage        | Use the Terraform module for Key Vault-backed flow  |
| No ACA health probes yet          | Restart policy handles crashes; liveness only if added must hit `/healthz`, never `/healthz/ready` (license-gated → first-run deadlock) | When you want orchestrator-level health gating |
| Wildcard cert is BYO PFX          | Azure managed certs don't issue wildcards            | Front Door / App Gateway with a managed wildcard    |

## Pulling a new Broch image

Set `containerImage` to the new tag and re-deploy:

```sh
az deployment group create -g broch-rg --template-file mainTemplate.bicep \
  --parameters parameters.bicepparam containerImage=ghcr.io/broch-io/broch:1.6.0
```

Container Apps rolls out a new revision; the old one drains per the ingress traffic config.

## Teardown

```sh
az group delete --name broch-rg --yes
```
