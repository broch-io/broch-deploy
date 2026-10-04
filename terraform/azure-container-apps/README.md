# Azure Container Apps Terraform module

> **Status: beta.** This module is a working starting point that automation exercises less than the VM appliance, [`bicep/azure-vm`](../../bicep/azure-vm/). Test it before you rely on it, or use that appliance.

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
                                    │   - min=1, max=1 (one replica) │
                                    └──────────────┬─────────────────┘
                                                   │ TCP:5432 (SSL)
                                    ┌──────────────▼─────────────────┐
                                    │ Postgres Flexible Server       │
                                    │   - B_Standard_B1ms (default)  │
                                    │   - private: delegated subnet, │
                                    │     no public endpoint         │
                                    └────────────────────────────────┘

    The Container Apps environment and the database share a private VNet
    (default 10.2.0.0/16, `vnet_address_space`). App ingress stays public.

                                    ┌────────────────────────────────┐
                                    │ Key Vault                      │
                                    │   - master-key                 │
                                    │   - auth-client-secret         │
                                    │   - postgres-connection-string │
                                    │   - RBAC: identity is reader   │
                                    └────────────────────────────────┘
```

## Prerequisites

- Terraform 1.6+
- Azure CLI logged in (`az login`) with permission to register resource providers. The provider block registers the ones this module needs (Microsoft.App, Microsoft.ContainerService, Microsoft.DBforPostgreSQL, Microsoft.KeyVault, Microsoft.ManagedIdentity, Microsoft.Network, Microsoft.OperationalInsights) on the first plan or apply, which takes 5-10 minutes on a fresh subscription. Microsoft.ContainerService is needed because the Container Apps environment runs in the module's own VNet.
- Either Owner or Contributor + User Access Administrator on the target subscription (you need to assign Key Vault RBAC roles).
- DNS control for your wildcard hostname's parent domain. Container Apps doesn't manage DNS for you — you create records by hand or via your DNS provider's Terraform module.
- An identity provider app registration (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `auth_audience`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it.
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

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

`terraform plan` refuses sign-in settings Broch would refuse at startup: an unknown `auth_provider`, a missing client ID or secret, or a value your provider needs (Auth0 and Okta need `auth_domain`, AzureAd and EntraExternalId need `auth_instance` and `auth_tenant_id`, each unless you set `auth_authority` instead; Oidc needs `auth_authority`; Auth0 also needs `auth_audience`). Values saved later in the app don't count here; keep them in `terraform.tfvars` too.

**Upgrading a deployment made with an earlier version of this module**, which gave Postgres a public endpoint: this upgrade **replaces the database server, and its data is lost**. Run `pg_dump` against the old server before you apply; the new server has no public endpoint, so the restore has to run from a host inside the VNet (see the tradeoffs table below). The plan also replaces the Container Apps environment (re-do the custom-domain binding below, with the new IP and verification ID). The database server carries `prevent_destroy`, so the plan stops until you deliberately delete that line in `database.tf` (put it back after the apply).

**Upgrading a checkout initialised before this module moved to azurerm 5.x:** run `terraform init -upgrade` instead of `terraform init`, or init fails because your local `.terraform.lock.hcl` still pins azurerm 4.x.

**Tearing down:** if `terraform destroy` stops with `polling support for the Content-Type "" was not implemented` while deleting the Container App or its environment, run `terraform destroy` again. Azure has already deleted the resource; the provider fails while checking on it, and the second run finishes the teardown.

That gets the Container App running, but the **custom-domain binding requires a separate manual step** because Azure needs you to prove DNS control before it'll bind the cert.

## Binding the custom domain (one-time, post-apply)

After the first `terraform apply` completes:

```sh
# 1. Get the verification ID + the app's default hostname
VERIF_ID=$(terraform output -raw container_app_verification_id)
APP_FQDN=$(terraform output -raw container_app_fqdn)
HOSTNAME=$(terraform output -raw broch_url | sed 's|https://||')

# 2. Add these DNS records in your provider:
#      A     <hostname>           → the environment's static IP (what $APP_FQDN resolves to)
#      TXT   asuid.<hostname>     → $VERIF_ID
#    (Container Apps requires the TXT record to validate ownership.)

# 3. Bind the custom domain + provision an Azure-managed cert. An A record pairs with HTTP
#    validation (a CNAME record would pair with --validation-method CNAME instead).
az containerapp hostname bind \
  --hostname "$HOSTNAME" \
  --resource-group broch-rg \
  --name broch-app \
  --validation-method HTTP

# Re-run as needed if cert provisioning hasn't propagated yet (~5-10 min).
```

**Wildcard cert is a separate problem.** Azure Container Apps' built-in managed certs **don't issue wildcards**. For tunnel subdomains (`*.broch.example.com`), you have three options:

1. **Front Door / Application Gateway** in front of Container Apps, serving a wildcard cert you provide (from Key Vault); neither issues a managed wildcard for you. Adds ~$35/mo for Front Door but is the cleanest production answer.
2. **Provision a wildcard cert separately** (Let's Encrypt via certbot+DNS, or commercial CA) and upload it via `az containerapp env certificate upload` + `az containerapp hostname bind`.
3. **Skip wildcards** entirely if your deployment doesn't use tunnel subdomains.

The README at the repo root flags this as the main Azure-vs-AWS tradeoff: AWS gets wildcard certs in-stack via ACM, Azure makes you do extra work.

## How secrets flow at runtime

1. Variables → Key Vault on `terraform apply` (writer role: the human running TF)
2. Container App's user-assigned identity has the Key Vault Secrets User role
3. Container App `secret { }` blocks reference each Key Vault entry by its versioned URI (the version Terraform last wrote)
4. Container `env { secret_name = ... }` blocks map secrets into env vars (`AUTHENTICATION__CLIENTSECRET`, `BROCH_MASTER_KEY`, `ConnectionStrings__BrochConnection`). Non-secret IdP config (`AUTHENTICATION__PROVIDER`, `CLIENTID`, `ADMINROLES`, …) is passed as plain `env`. The master key is generated by Terraform (`random_password`), not supplied — it's the at-rest encryption root the server requires at boot. The license is not a boot input — it's activated in-app on first sign-in. The broch image is public, so no registry credentials are needed.

Rotate through Terraform, not `az keyvault secret set`: the app keeps reading the pinned version, so a direct edit is never picked up, and the next `apply` reverts it. Set the new value (for the IdP secret, `auth_client_secret`) and run `terraform apply` twice: the first writes the new secret version, the second points the app at it (it changes nothing if the first already did). Then restart the active revision so it loads the new value:

```sh
az containerapp revision restart -n broch-app -g broch-rg \
  --revision "$(az containerapp revision list -n broch-app -g broch-rg --query '[0].name' -o tsv)"
```

`broch-app` and `broch-rg` are the names the default `name_prefix` (`broch`) gives; substitute yours if you changed it.

Terraform state holds every secret in plaintext; keep it access-controlled (e.g. an encrypted remote backend).

## Tradeoffs / what's deliberately not here

| Decision                                | Why                                            | When to change                                                                                |
| --------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `min=1, max=1`                          | Broch runs as one instance and doesn't cluster | Keep it; scale up with `container_cpu` / `container_memory`                                   |
| No zone redundancy on Postgres          | Cheapest tier                                  | When you need HA                                                                              |
| Single revision mode                    | Broch runs as one instance and doesn't cluster | Keep it; leaving two revisions active would run two Broch instances on one database           |
| No Front Door                           | Wildcard cert problem documented; FD adds cost | When you're past the proof-of-concept phase                                                   |
| Postgres reachable only inside the VNet | No public database endpoint                    | To administer it, use a VM or Cloud Shell attached to the VNet, or peer a network you control |
| `prevent_destroy` on the Postgres server | A destroy or replacing change can't delete the database | Delete the line in `database.tf` only for an intentional destroy (see Teardown)          |

## Pulling a new broch image

Update the tag and re-apply:

```sh
$EDITOR terraform.tfvars       # set broch_image = "ghcr.io/broch-io/broch:<version>"
terraform apply
```

Container Apps creates a new revision with the new image. In single revision mode it keeps the old revision until the new one is ready, then sends all traffic to the new one and deactivates the old; open tunnels drop and reconnect.

## Teardown

The database server carries `prevent_destroy`, so a destroy stops at plan until you delete that line from `database.tf` (it is the guard against losing the database by accident):

```sh
$EDITOR database.tf            # delete `prevent_destroy = true`
terraform destroy
```

Key Vault soft-delete with purge protection keeps the destroyed vault, and the master key in it, recoverable for 7 days (`az keyvault recover --name <vault-name>`); it cannot be purged early. A re-apply is unaffected: the vault name carries a random suffix, so it never collides with the deleted one.

Azure releases the subnets a few minutes after it deletes the Container Apps environment and the Postgres server. If `terraform destroy` stops on a subnet that is still in use, wait and run it again. Azure also deletes the environment's own `<resource-group>-aca-infra-<suffix>` group by itself.
