# Azure Container Apps — Bicep template

Broch on Azure Container Apps, deployed with Bicep.

By default (`databaseMode=Embedded`) it's a self-contained single-replica **evaluation** stack: the Broch server plus a PostgreSQL sidecar on **ephemeral storage**. The database does not survive revision restarts, image upgrades, or platform maintenance — each one returns the app to first-run state (re-enter IdP config, re-activate the license). That's the point: click, deploy, evaluate, no other resources to manage.

For production, set `databaseMode=Managed` (the template provisions a private Azure Database for PostgreSQL Flexible Server in its own VNet, with `postgresAdminPassword` as its admin password) or `databaseMode=Shared` (point `databaseConnectionString` at a PostgreSQL you run), or use the [Terraform Azure module](../../terraform/azure-container-apps/) (beta), which provisions Postgres Flexible Server + Key Vault.

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
                                    │     (ephemeral EmptyDir volume │      (evaluation only)
                                    │      — data lost on revision   │
                                    │      restarts and upgrades)    │
                                    │   - secrets inline in config   │
                                    └────────────────────────────────┘

  Managed mode (production): no sidecar; the template provisions a private
  Postgres Flexible Server and puts the environment in its VNet.
  Shared mode (production): no sidecar; point databaseConnectionString at
  your own Postgres instead.

  Optional: Log Analytics + Application Insights are created when
  telemetryProvider=ApplicationInsights and no connection string is supplied.
```

## Prerequisites

- Azure CLI logged in (`az login`) against a subscription with the resource providers this template uses registered: Microsoft.App, Microsoft.OperationalInsights, Microsoft.Insights (with Application Insights telemetry), and for `databaseMode=Managed` also Microsoft.DBforPostgreSQL, Microsoft.Network and Microsoft.ContainerService (needed for a Container Apps environment in a custom VNet). Register any that are missing with `az provider register -n <namespace>` before deploying (it can take 5-10 minutes).
- Contributor on the target resource group.
- DNS control for your wildcard hostname's parent domain — Container Apps doesn't manage DNS for you.
- An identity provider app registration (Auth0, Entra ID / Azure AD, Okta, or any OIDC) — Broch has no built-in local login. Either set it here (`authProvider`, `authClientId`, `authClientSecret` and the provider's own values: setting any one of them makes the rest required) or leave every sign-in parameter blank and set it up in the app after deploying. `authProvider` no longer defaults to `AzureAd`: set it explicitly (a parameters file from an earlier version that set the other sign-in values and relied on that default now fails preflight, naming `authProvider`). See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `authAudience`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it.
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

> **The master key is yours to keep.** `masterKey` is the at-rest encryption root — Broch, LLC never sees it. Generate it with `openssl rand -base64 48` (the template requires at least 32 characters; the server rejects values under 32 bytes at boot), store it in your own secret store, and supply the same value on every redeploy. Rotating it invalidates anything DataProtection-wrapped in the database (refresh tokens, persisted license, usage blob).

## Custom domain + wildcard TLS

Broch issues tunnels on `*.<wildcardHostname>`, so you need the base host **and** its wildcard bound. Unlike the Terraform module — where Azure's managed certs can't issue wildcards — this template binds a **wildcard cert you supply** as a base64 PFX:

```sh
# Convert your wildcard PFX to base64 and pass it in:
#   sslCertificatePfxBase64 = "$(base64 -w0 wildcard.pfx)"
#   sslCertificatePassword  = "<pfx-password>"
#   customDomainHostname         = "broch.example.com"
#   customDomainWildcardHostname = "*.broch.example.com"
```

Before the binding validates, Azure needs to prove you control the domain:

```sh
# Get the verification ID and the app's default hostname
APP_FQDN=$(az containerapp show -g broch-rg -n <siteName> --query properties.configuration.ingress.fqdn -o tsv)
VERIF_ID=$(az containerapp env show -g broch-rg -n <siteName>-env --query properties.customDomainConfiguration.customDomainVerificationId -o tsv)

# Add DNS records at your provider:
#   A     broch.example.com        → IP of $APP_FQDN
#   TXT   asuid.broch.example.com  → $VERIF_ID
#   A/CNAME for the wildcard *.broch.example.com → same target
```

Re-run the deploy once DNS has propagated and the cert/binding will complete.

## How secrets flow at runtime

This template keeps secrets **inline in the Container App configuration** (the `secrets` block), referenced from env via `secretRef` — there's no Key Vault. The values are written once at deploy time from your parameters:

- `master-key` → `BROCH_MASTER_KEY`
- `db-connection` → `ConnectionStrings__BrochConnection`
- `postgres-password` → the sidecar's `POSTGRES_PASSWORD` (Embedded mode)
- `auth-client-secret` → `AUTHENTICATION__CLIENTSECRET`

Rotate by re-running the deploy with the new value, or `az containerapp secret set` followed by a revision restart. If you want Key Vault-backed secrets, use the [Terraform module](../../terraform/azure-container-apps/) instead.

## Tradeoffs / what's deliberately not here

| Decision                          | Why                                                  | When to change                                      |
| --------------------------------- | ---------------------------------------------------- | --------------------------------------------------- |
| Embedded sidecar is ephemeral     | Evaluation mode — nothing kept, nothing to manage    | `databaseMode=Managed` or `Shared` for production   |
| Single replica                    | Broch runs as one instance and doesn't cluster       | Keep `maxReplicas` at 1; tunnels pin to a replica   |
| Secrets inline, no Key Vault      | One fewer resource + role assignment to manage       | Use the Terraform module for Key Vault-backed flow  |
| Liveness probe only (`/healthz`)  | Restarts a container that's TCP-alive but HTTP-hung  | —                                                   |
| Wildcard cert is BYO PFX          | Azure managed certs don't issue wildcards            | — (Front Door / App Gateway need your cert too)     |

Two of these deserve the long version. *Ephemeral:* Azure Files can't host the sidecar's data — SMB has no chmod and postgres `initdb` requires it — so Embedded data lives on a replica-scoped EmptyDir volume and is lost on revision restarts, image upgrades, and platform maintenance, returning the app to first-run state (re-enter IdP config, re-activate the license). *No readiness probe:* `/healthz/ready` is license-gated, and gating ingress on it deadlocks first-run activation — no traffic means no setup UI means no license.

## Pulling a new Broch image

Set `containerImage` to the new tag and re-deploy:

```sh
az deployment group create -g broch-rg --template-file mainTemplate.bicep \
  --parameters parameters.bicepparam containerImage=ghcr.io/broch-io/broch:<version>
```

Container Apps starts a new revision and switches traffic to it. The two revisions overlap briefly, and this is not a seamless handover: tunnels connected to the old revision drop, and clients reconnect to the new one after the switch.

## Teardown

If you deployed into a **dedicated resource group** (nothing else in it), one line removes everything:

```sh
az group delete --name broch-rg --yes
```

In `Managed` mode, everything includes the Flexible Server the template provisioned, and your database with it: back it up first.

**In Shared mode — or any resource group that also holds your database or other resources** — do **not** delete the group; it takes them with it. Delete only what this template created:

```sh
az containerapp delete     -g broch-rg -n <containerAppName> --yes
az containerapp env delete -g broch-rg -n <environmentName>  --yes
# + the Log Analytics workspace / Application Insights, if the template created them
# + in Managed mode, once the database is backed up: the Flexible Server, its VNet and private DNS zone
```
