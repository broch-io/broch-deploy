# Azure VM — Bicep template

Broch on a single Azure VM, deployed with Bicep. **This is the same template Broch, LLC runs for its own production deployment** — what you deploy here is what we run.

The VM runs the canonical [`with-postgres-external` + Caddy compose stack](../../docker-compose/with-postgres-external/) **verbatim** (cloud-init embeds it at deploy time, so the box runs the same bytes as a docker-direct deploy). You choose:

- **Database** — `databaseMode=Existing` (bring your own reachable PostgreSQL 14+ via a connection string), `databaseMode=Managed` (the template provisions a **private** Azure Database for PostgreSQL Flexible Server — VNet-injected, no public endpoint), or `databaseMode=Local` (PostgreSQL runs **on the VM** on a small dedicated data disk — zero DB prerequisites, but **you manage backups**; see [Local database](#local-database)).
- **TLS** — `certMode=Auto` (Caddy issues + auto-renews the apex + wildcard via ACME DNS-01; `dnsProvider=Cloudflare` with an API token, or `AzureDns` with the VM's managed identity — **no secret**) or `certMode=Byo` (supply your own wildcard cert + key).

**Bring your own domain.**

For the click-to-evaluate path with no VM to manage, see the [ACA Bicep](../azure-container-apps/) instead.

## What this provisions

```text
                                  ┌─────────────────────────────────────┐
internet ─ 80/443/443udp ───────▶ │ Azure VM — static public IP, NSG    │
                                  │   caddy  — wildcard TLS, ACME DNS-01 │
                                  │     ↳ HTTP ─▶ broch (8080, internal) │
                                  └──────────────────┬──────────────────┘
                                                     │ TCP:5432 (SSL)
                                                     ▼
                                  ╔═════════════════════════════════════╗
                                  ║ Your external PostgreSQL            ║
                                  ║   (Azure Flexible Server, RDS, …)   ║
                                  ╚═════════════════════════════════════╝

  The VM is stateless: broch + caddy from the canonical with-postgres-external
  compose, started by systemd. All state lives in the external DB. SSH is closed
  by default — manage via `az vm run-command` / Azure Serial Console.
```

- An Ubuntu 24.04 VM (default x86 `Standard_B2s`; ARM64 is a one-line opt-in via the `vmSize`/`imageSku` params where Ampere capacity exists).
- A **static** Standard public IP — the address your DNS points at.
- An NSG: HTTP (80) + HTTPS/HTTP-3 (443 tcp+udp) from the internet. SSH (22) is **closed by default**; set `sshAllowedCidr` to a CIDR for break-glass SSH.
- cloud-init that drops in the canonical compose + Caddyfile + Caddy.Dockerfile, writes the **non-secret** `.env`, **fetches the secrets (master key, DB credential, IdP secret, DNS-01 tokens) from Key Vault at boot** (see [Secrets & break-glass](#secrets--break-glass)), installs Docker, and starts the stack via systemd. With `databaseMode=Local` it also runs Postgres on a dedicated data disk (see [Local database](#local-database)).

Telemetry, logging, and the license are configured **in-app** (Admin → …) after first sign-in — not in the deploy.

## Sizing

At **idle** (Local mode), the three containers total **~700 MB** resident — Caddy ~68 MB, broch/.NET ~205 MB, Postgres ~25–60 MB; the rest is the OS. cloud-init also provisions a **2 GB swapfile** for headroom on small/burstable sizes.

| `vmSize` | vCPU / RAM | Notes |
| --- | --- | --- |
| `Standard_B1ms` | 1 / 2 GiB | **Floor** — comfortable at idle (~1.2 GiB free, swap untouched). The single vCPU is the limiter under concurrency. |
| `Standard_B2s` | 2 / 4 GiB | **Recommended default** — the 2nd vCPU noticeably speeds boot convergence (ACME issuance, .NET JIT). |

> **The real workload is SSH tunnels.** Broch's load is long-lived tunnel connections, so the operative cost is `~700 MB baseline + (concurrent tunnels × per-tunnel cost)`. Per-tunnel cost is **small** — on the order of **1–2 MB RAM and a small fraction of a vCPU per concurrent tunnel** at idle, scaling modestly with relayed throughput. At these sizes the **single vCPU is the binding constraint** (connection count + keepalive), not RAM — memory has comfortable headroom on `B1ms` and the swapfile is a further cushion. `B1ms` is the **floor** and `B2s` the recommended **default**; do not size below `B1ms` for a production deployment.

## Prerequisites

- Azure CLI logged in (`az login`), Contributor on the target resource group. **Owner or User Access Administrator** is needed only if you let the template auto-grant the Azure-DNS role (below) or set `adminObjectId` — both create role assignments.
- A database — **one of**: an existing **PostgreSQL 14+** reachable from the VM with a least-privilege role that owns its own database (`databaseMode=Existing`; see [Database setup](#database-setup)); let the template provision one (`databaseMode=Managed` — you set `postgresAdminPassword`); or run it **on the VM** with nothing to pre-arrange (`databaseMode=Local` — you manage backups; see [Local database](#local-database)).
- For `certMode=Auto`, DNS for your wildcard hostname on a supported provider: **Cloudflare** (API token, Zone:Read + DNS:Edit) **or** **Azure DNS** (no secret — uses the VM's managed identity). With Azure DNS, set `dnsZoneResourceGroup` and the template **grants the identity *DNS Zone Contributor* on that resource group automatically** (needs Owner/UAA there); if you only have Contributor, leave it empty and grant the role by hand. For `certMode=Byo`, a wildcard cert + key — no DNS provider needed.
- An identity provider app (Auth0, Entra ID / Azure AD, Okta, or any OIDC) — Broch has no built-in local login, so the IdP is configured at boot. Register the callback `https://<shareSubdomain>.<dnsZone>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- **A master key** — generate with `openssl rand -base64 48` and store it in your own secret store. **Required** (≥32 chars); supply the same value on every (re)deploy. Broch never sees it. For an existing Broch database it must be that database's key.
- **No SSH key to prepare** — SSH is closed by default and the VM gets a generated break-glass password (`adminSshPublicKey` is an optional advanced override; the password lands in a Key Vault — see [Secrets & break-glass](#secrets--break-glass)).
- A Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Database setup

*Only for `databaseMode=Existing`. `Managed` (provisions a private Flex Server) and `Local` (runs Postgres on the VM — see [Local database](#local-database)) need no pre-setup — skip this section.*

The VM connects as a least-privilege role that owns **only its own database** — never the server admin (which would expose every database on the server). As the server admin, from a host allowed through the DB firewall:

```sql
-- connected to the default 'postgres' database:
CREATE ROLE broch LOGIN PASSWORD '<generated>';
ALTER DATABASE brochdb OWNER TO broch;

-- then connected to 'brochdb' — REQUIRED on PG15+: the database owner does NOT
-- automatically get CREATE on the public schema, so migrations otherwise fail with
-- "42501: permission denied for schema public":
ALTER SCHEMA public OWNER TO broch;
```

After the VM deploys, add its public IP (a deployment output) to the database server's firewall.

## Local database

`databaseMode=Local` runs PostgreSQL **on the VM** (the bundled [`with-postgres`](../../docker-compose/with-postgres/) compose) — **nothing to set up first**. The template generates the Postgres password and provisions a small **dedicated data disk** (`dataDiskSizeGb`, default **4 GiB** Standard SSD — Broch's database is tiny; size up only if you retain large audit/request-log history). cloud-init mounts that disk at `/var/lib/docker/volumes`, so the database lives on it and **survives reboots and VM recreation** — the disk is a *separate* resource, so a from-scratch reprovision (or `az vm delete` + redeploy) reattaches it with data intact. The generated Postgres password is **derived** (from the resource group + VM name), so it stays the same across a recreate and still matches the surviving database. You can override it with **`localDbAdminPassword`** (re-supply the same value on every redeploy). The password value is stored in **Key Vault** (see [Secrets & break-glass](#secrets--break-glass)) and fetched at boot — it is **not** in `customData`, so a plain subscription **Reader** can't read it (that needs *Key Vault Secrets User*). The one residual note: the *derived default* is computable from the (public) resource names, so set an explicit `localDbAdminPassword` if you don't want it formula-derivable. Either way Postgres has **no host port** — the blast radius is in-container code execution, not the network.

> **If you script recreation/reprovisioning of a Local-mode VM,** that automation must (a) **not delete** the `<vmName>-data` disk, (b) re-pass `databaseMode=Local` — otherwise the new VM boots in the default mode with the disk orphaned (a deploy that "succeeds" but runs the wrong/empty database) — and (c) deploy with **`--mode Incremental`** (the default). A `--mode Complete` deploy of this resource group with `databaseMode != 'Local'` **deletes** the `<vmName>-data` disk outright, since the disk is absent from the template for non-Local modes. Broch's own `reprovision-{dev,prod}-vm.yml` workflows use `Existing` mode and are **not** Local-aware.

**Sizing.** Choose `dataDiskSizeGb` at first deploy. Increasing it on a later redeploy resizes the Azure disk but does **not** auto-grow the ext4 filesystem — after the redeploy, run `sudo resize2fs /dev/disk/azure/scsi1/lun0` on the VM to use the new space (and note some disk tiers require a VM deallocate to resize). Shrinking is not supported.

**Zero-downtime (blue-green) upgrades aren't available in Local mode.** A blue-green swap stands up a replacement VM and cuts traffic to it while the old one still serves — which needs an **external, shared** database both VMs reach at once. Local keeps the database on a disk attached to a single VM, so there is nothing to share. A Local upgrade is therefore the recreate-and-reattach described above (the same `<vmName>-data` disk reattaches to the new VM), with a brief outage while it boots. Choose `Existing` or `Managed` if you need zero-downtime deploys.

**Backups are yours.** Local has **no automated backups or point-in-time restore** — choose `Managed` or `Existing` if you need those. Back the Local database up yourself.

**Azure disk snapshot** (simplest) — snapshot the `<vmName>-data` disk on a schedule:

```sh
az snapshot create -g <rg> -n broch-data-$(date +%Y%m%d) \
  --source "$(az disk show -g <rg> -n <vmName>-data --query id -o tsv)"
```

**Logical dump** — `pg_dump` from the VM (no SSH needed):

```sh
az vm run-command invoke -g <rg> -n <vmName> --command-id RunShellScript --scripts \
  'docker exec broch-postgres-1 pg_dump -U broch brochdb | gzip > /opt/broch/backup-$(date +%F).sql.gz'
```

## Setup

```sh
# 1. Authenticate
az login
az account set --subscription <subscription-id>

# 2. Resource group
az group create --name broch-rg --location eastus

# 3. Fill in parameters
cp main.example.bicepparam main.bicepparam
$EDITOR main.bicepparam   # gitignored — non-secret values; pass secrets on the CLI below

# 4. Deploy (secrets via --parameters, never committed)
# brochMasterKey is REQUIRED — generate with `openssl rand -base64 48`, store it, and pass the
# SAME value on every (re)deploy. For an existing DB, use that database's key. No SSH key needed.
az deployment group create \
  --resource-group broch-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters \
      brochMasterKey='<openssl-rand-base64-48>' \
      databaseConnectionString='Host=broch.postgres.database.azure.com;Database=brochdb;Username=broch;Password=<pw>;SSL Mode=Require' \
      cloudflareApiToken='<token>' \
      authClientSecret='<secret>'

# 5. Read the public IP
az deployment group show -g broch-rg -n main \
  --query properties.outputs.publicIpAddress.value -o tsv
```

> **The master key is yours to keep.** `brochMasterKey` is the at-rest encryption root — Broch, LLC never sees it. It is **required**: generate it with `openssl rand -base64 48`, store it in your own secret store, and supply the **same** value on every (re)deploy (the template requires ≥32 chars; the server rejects values under 32 bytes at boot). For an **Existing** database it must be that database's key — a different key cannot decrypt its Data Protection keyring (recoverable: users re-auth and the license re-activates, but disruptive). Rotating it invalidates anything DataProtection-wrapped in the database (refresh tokens, persisted license, usage blob).

## TLS — certificate & DNS

You give the domain as two parts — `dnsZone` (a zone you own, e.g. `example.com`) and `shareSubdomain` (the label that hosts tunnels, default `tunnels`) — and Broch composes the public host `<shareSubdomain>.<dnsZone>` (e.g. `tunnels.example.com`), serving that apex and `*.<shareSubdomain>.<dnsZone>`. Capturing them separately means the tunnel host is **always within the zone** by construction. Set `shareSubdomain=''` to serve at the zone apex (`example.com` and `*.example.com`). Broch needs a **wildcard** cert covering both; `certMode` / `dnsProvider` decide how Caddy gets it:

**`certMode=Auto` — Let's Encrypt, auto-renewing.** Caddy issues + renews the apex + wildcard via ACME DNS-01 (the only ACME challenge that issues wildcards), minting the cert against the DNS provider's API *before* any DNS points at the VM — so you validate first, cut DNS over last.

All provider modules are compiled into the broch-caddy image, so the choice is pure config:

- `dnsProvider=AzureDns` — Azure DNS via the VM's **managed identity** (no secret). Set `dnsZoneResourceGroup`; the template **grants the identity *DNS Zone Contributor* on that resource group automatically** (no manual step). The role assignment needs the deployer to have **Owner / User Access Administrator** on the zone's RG; with only Contributor, use `AzureDnsServicePrincipal` instead, or leave `dnsZoneResourceGroup` empty and grant the identity (`managedIdentityPrincipalId` is a deployment output) the role by hand. RBAC propagation is eventual — Caddy retries until it lands. The grant is **RG-scoped** (Caddy's Azure module resolves the zone from the hostname, so it can't be zone-scoped) — if that RG holds multiple DNS zones, consider putting the Broch zone in its own resource group so the VM gets contributor on only the one zone.
- `dnsProvider=AzureDnsServicePrincipal` — Azure DNS via a **service principal** you supply (`azureTenantId` + `azureClientId` + `azureClientSecret`), pre-granted DNS Zone Contributor on the zone. No deploy-time role assignment, so **Contributor is enough to deploy**. Also set `dnsZoneResourceGroup`.
- `dnsProvider=Cloudflare` — set `cloudflareApiToken` (Zone:Read + DNS:Edit).
- `dnsProvider=Route53` — set `awsAccessKeyId` + `awsSecretAccessKey` (Route 53 list+change rights on the zone).
- `dnsProvider=GoogleCloudDns` — set `gcpProject` + `gcpCredentialsJson` (base64 service-account key, roles/dns.admin).
- `dnsProvider=DigitalOcean` — set `doAuthToken` (DNS write scope).

**`certMode=Byo` — your own cert.** Supply `tlsCertificate` + `tlsCertificateKey` (base64 PEM covering apex + wildcard). No ACME / DNS-01 — but **renewal is yours** (replace the files, then recreate Caddy).

Watch issuance:

```sh
az vm run-command invoke -g broch-rg -n <vmName> --command-id RunShellScript \
  --scripts 'cd /opt/broch && docker compose logs --tail 50 caddy'
```

**DNS records — automatic by default.** With `dnsAutoRecords=Auto` (the default) the appliance
**creates and maintains the apex + wildcard A records for you**, pointing them at the VM's public IP
via the same `dnsProvider` credential Caddy uses for the cert — so a deploy goes straight to sign-in,
no records to create, and a changed IP self-heals. It manages `<shareSubdomain>` + `*.<shareSubdomain>`
(or the apex `@` + `*` when `shareSubdomain=''`) inside the **DNS zone that owns the host**. Normally
that is `dnsZone`; the records are written there and the labels are the host relative to it. On Cloudflare the records are created
**DNS-only / grey-cloud** (proxying can't carry tunnel traffic). The records live in **your** zone, so
they **outlive teardown** — delete them by hand if you tear the VM down.

**Delegated (subdomain) zones — `dnsZoneName`.** Auto-DNS writes into the zone that actually **owns**
the host. Normally that is `dnsZone`, so leave `dnsZoneName` **empty** (default) — behaviour is
unchanged. But if your DNS is a **delegated subdomain** — the host lives in its own zone that is a
subdomain of `dnsZone` (e.g. `dnsZone=example.com` for the URLs, but `share.example.com` is delegated
as its own zone) — set **`dnsZoneName`** to that zone. The appliance then writes the records there and
derives the labels as the host relative to it. This is the same zone Caddy resolves for the cert, so a
valid cert can no longer coexist with A-record writes that 404. A `dnsZoneName` that is neither the host
nor a parent of it is **rejected** (auto-DNS is skipped and logged; DNS stays manual) rather than
writing a broken record. The Azure Marketplace wizard fills this from the DNS zone you pick.

Set **`dnsAutoRecords=Manual`** when something sits **in front of** the VM (a load balancer, reverse
proxy, or corporate NAT/egress) — its IP, not the VM's, is what clients must resolve — or when you
manage DNS out-of-band. `certMode=Byo` forces Manual (no DNS credential). In Manual mode, point DNS at
the public IP yourself, **DNS-only / grey-cloud**:

```text
A   tunnels.example.com    → <public-ip>
A   *.tunnels.example.com  → <public-ip>
```

Sign in at `https://<shareSubdomain>.<dnsZone>` (e.g. `https://tunnels.example.com`) — the first user holding an `AUTHENTICATION__ADMINROLES` role becomes admin.

## Secrets & break-glass

**Key Vault (app secrets).** The deployment **always** creates a Key Vault (**access-policy mode**, name in the `keyVaultName` output) holding the deploy-time **app** secrets, which the VM's **user-assigned managed identity** reads at boot (a `get`-only access policy) and writes into `/opt/broch/.env` — so the secret **values never enter the VM's `customData`** (which a subscription Reader can decode):

- `broch-master-key` — the at-rest encryption root (customer-supplied; never generated). It is still born in your tenant and never transits Broch — Key Vault is just where the VM reads it from at boot.
- `db-connection-string` (Existing/Managed) **or** `postgres-password` (Local) — the database credential
- `auth-client-secret` — the IdP client secret (when set)
- `cloudflare-api-token` / `azure-dns-client-secret` / `aws-access-key-id` / `aws-secret-access-key` / `do-auth-token` — Caddy's DNS-01 credential (only the one your provider needs)

The deployment writes these via the control plane and grants the VM identity read via a vault **access policy** — both covered by **Contributor** on the resource group, so the **whole secrets path deploys as a plain Contributor** (no Owner / User Access Administrator). The one exception is `dnsProvider=AzureDns` managed-identity mode, which still creates a DNS-Zone-Contributor *role assignment* (needs Owner/UAA on the zone RG); every other path is Contributor-only. Access policies also take effect immediately — no AAD-RBAC replication lag — so the boot-fetch isn't racing grant propagation (its retry loop stays as belt-and-suspenders). To read the secrets yourself, add an access policy (or *Key Vault Secrets User*) for your principal on this vault.

> **Tradeoff of access-policy mode:** adding access policies is itself a Contributor-level action, so anyone with **Contributor on this resource group** can grant themselves secret-read and read the app secrets. This is **not a new exposure** — a Contributor already has VM-level access (`az vm run-command` → `cat /opt/broch/.env`), so the vault is not a boundary against RG Contributors either way. The win over `customData` is against a subscription **Reader** (who could base64-decode `customData` but cannot read the vault), plus the break-glass password staying in the RBAC vault below that a Contributor **cannot** self-grant. Restrict resource-group Contributor membership accordingly.

**Break-glass password — a SECOND, isolated vault.** When no SSH key is supplied, the generated `vm-admin-password` is stored in its **own** Key Vault (name in the `breakGlassKeyVaultName` output, `<vmName>-bg-<id>`) that the **VM identity has no access to** — so a compromise of broch can't use the VM identity to read the host break-glass password. Set `adminObjectId` at deploy time and the template grants *you* read on **just that one secret** (or grant yourself *Key Vault Secrets User* on that vault manually). **Upgrading an earlier deployment:** this version uses **distinct** vault names — the app-secrets vault is `<vmName>-app-<id>` (`keyVaultName` output, access-policy mode) and the break-glass password moves to `<vmName>-bg-<id>` (`breakGlassKeyVaultName`, RBAC). The earlier template's single `<vmName>-kv-<hash>` vault (which held `vm-admin-password` in RBAC mode) is **left orphaned on purpose**: re-using that exact name would force an RBAC→access-policy permission-model flip on the existing vault, which needs Owner/UAA — so the app vault takes a fresh name to stay **Contributor-deployable**. Update any runbook that read `vm-admin-password` via `keyVaultName`, and delete the orphaned `<vmName>-kv-<hash>` vault by hand once the new deploy is confirmed healthy. (Deployed **with** an SSH key originally? The old template created no vault, so nothing is orphaned — you simply get the two new vaults.)

> ⚠️ **The break-glass password rotates on every redeploy.** `vmPasswordSeed` defaults to a fresh value each `az deployment group create`, so the `vm-admin-password` secret is overwritten on every run — even a routine redeploy to bump `brochVersion` or change a DNS provider. Any out-of-band copy of the old password stops working; re-read it from the break-glass vault after each deploy. To keep a stable password across redeploys, pass an explicit `vmPasswordSeed` (and store it yourself). Note the vault copy tracks the **latest deployment**, while an existing VM keeps its original password (Azure ignores `adminPassword` changes on a re-PUT) — after a retry over a live VM, reset with `az vm user update` if Serial Console is ever needed.

**VM access.** Inbound SSH is closed by default. The box is managed via `az vm run-command` (Azure RBAC — no SSH) and **Azure Serial Console** (sign in as `broch` with the `vm-admin-password` from the break-glass vault above). Supply `adminSshPublicKey` only if you specifically want key-based SSH (then also open `sshAllowedCidr`).

**Runtime config.** `/opt/broch/.env` (mode `0600`) holds the config the compose reads. cloud-init writes the **non-secret** keys (hostname, provider names, IdP client id, etc.) from the deploy parameters; at boot the VM's identity **fetches the secrets from Key Vault and appends them** to the same file:

- `BROCH_MASTER_KEY` → broch's at-rest encryption root
- `BROCH_DB_CONNECTION_STRING` → `ConnectionStrings__BrochConnection` (mapped in compose)
- `AUTHENTICATION__CLIENTSECRET` → the IdP client secret
- `CLOUDFLARE_API_TOKEN` → Caddy's DNS-01 credential (Cloudflare mode)
- `AZURE_DNS_SUBSCRIPTION_ID` / `AZURE_DNS_RESOURCE_GROUP` / `AZURE_DNS_TENANT_ID` / `AZURE_DNS_CLIENT_ID` → Caddy's DNS-01 config for **Azure DNS** (cert issuance only — *not* the `AUTHENTICATION__*` IdP sign-in config; managed-identity mode uses only subscription + resource group; service-principal mode adds `AZURE_DNS_CLIENT_SECRET`, fetched from Key Vault)

Rotate a secret by updating it in **Key Vault** and reprovisioning the VM (the boot-fetch re-reads it), or edit `/opt/broch/.env` directly and run `docker compose up -d` (a **recreate** — `env_file` is only read at container create time, so a plain `docker restart` silently keeps the old values).

> **If the first-boot secret fetch fails** (e.g. the VM's managed-identity token isn't yet mintable via IMDS within the ~10-minute retry window, or the vault is unreachable — the app vault's access policy is immediate, so it is not a grant-propagation race), cloud-init aborts before enabling `broch.service`, so broch won't start — and because the fetch runs only on first boot, a plain reboot won't fix it. **Recover by redeploying**: the deploy is idempotent — the data disk and the Key Vault secrets are preserved, and the boot-fetch replaces rather than duplicates `.env` entries — so it simply completes the fetch and enables the service. (If you'd rather not redeploy, re-run the boot scripts on the host and inspect their output: `az vm run-command invoke -g <rg> -n <vmName> --command-id RunShellScript --scripts 'cloud-init single --name runcmd'` — broch starts only if the fetch succeeds, since the start gate still requires the completion sentinel.)
>
> **Still in `customData`:** the non-secret config, and — for now — the BYO TLS cert + key (`certMode=Byo`), the GCP service-account JSON (GoogleCloudDns), and the private-registry token (`registryPassword`; this one is also substituted into a runcmd, so it additionally appears in the VM's boot-diagnostics serial log, readable by VM Contributor — only relevant for private pre-release/beta image pulls, since it's empty for the public image). Moving those file/registry secrets to Key Vault too is a follow-up; the high-value secrets (master key, DB credential, IdP secret, DNS-01 tokens) are already Key Vault-only and absent from `customData`.

## Retrying a failed deployment

A deployment that fails partway (quota, capacity, a permissions error on the DNS role assignment) leaves the already-created resources in the resource group. **Do not start over in a new resource group.** Fix the cause (e.g. request the quota increase the error links), then retry the **same deployment into the same resource group**:

- **Portal — Azure's Redeploy button on the failed deployment (the intended path).** The form comes back with every **non-secret** parameter prefilled from the failed attempt. **Re-enter the master key — that is the whole retry.** Every other vault-backed secret may be left blank: blank never overwrites, the boot-fetch list derives from your selections, and the values the failed attempt stored in the Key Vault are reused (the Managed admin password included — the pg module reads it back via `getSecret()`). `brochMasterKey` is ARM-required, so an accidental empty submission is rejected at validation, before anything deploys.
- **CLI** — the same `az deployment group create`; only `brochMasterKey` must be re-supplied.
- If the attempt being retried was a **recovery deployment** (`recoverSoftDeletedVaults=true` — see [Key Vault soft-delete under Teardown](#teardown)), the prefilled flag is safe to leave as-is: the recover pre-pass is a no-op over live vaults.

Every resource re-PUTs idempotently, including the VM: the boot-fetch list baked into its `customData` derives from the **selections** (database mode, cert mode, DNS provider, auth provider), not from which params were supplied, so a retry produces byte-identical `customData` no matter which secret fields were filled — which matters because Azure **rejects** a `customData` change on an existing VM (`PropertyChangeNotAllowed`).

Rules of the retry:

- **Same non-secret selections** (region, modes, provider, names) as the failed attempt — the retry resumes that deployment; it is not a chance to change shape. The prefilled form gives you this for free.
- **The master key must be the SAME value** as the failed attempt (stored-key contract). Supplying a value in any other secret field **overwrites** the stored one — that is how you deliberately rotate a secret on a retry.
- The blank-reuse contract holds only for secrets the failed attempt actually **stored**. If the failure hit the Key Vault itself (nothing stored), re-enter the values; a blank whose secret was never stored fails **closed** — the boot-fetch halts on the missing vault secret and `broch.service` is never enabled (a Managed retry fails even earlier and louder: `getSecret` on the missing admin password is an ARM deployment error). Complete a boot-fetch brick by redeploying with the missing value and re-running the fetch (`az vm run-command ... 'cloud-init single --name runcmd'`), or delete the VM and redeploy.
- The customData-delivered inputs are the exception to blank-reuse: **BYO cert/key and the GCP service-account JSON** are not in the vault. On a retry over an existing VM they are simply ignored (the VM keeps its files); if the failure predated the VM, re-supply them or the box comes up without them (fails at cert issuance/serving).
- Corollary: `authProvider` set with **no client secret** (secretless/public-client OIDC) fails closed at the boot-fetch — unsupported via this template.
- The break-glass `vm-admin-password` rotates on every run (see the warning above); on a retry over an existing VM the vault copy diverges from the VM's real password — reset with `az vm user update -g <rg> -n <vmName> -u broch -p <new>` if Serial Console is ever needed there.

The Azure Marketplace wizard is deliberately **first-deployments-only** (conditional required/visible fields, which the raw form cannot do); the Redeploy button is the one retry surface.

## Pulling a new Broch image

The documented upgrade is the same in-place flow for everyone — edit one line + recreate:

```sh
az vm run-command invoke -g broch-rg -n <vmName> --command-id RunShellScript --scripts '
  cd /opt/broch
  sed -i "s|^BROCH_VERSION=.*|BROCH_VERSION=1.27.0|" .env
  docker compose pull broch && docker compose up -d broch'
```

Caddy keeps serving across the broch restart. Broch runs EF migrations on boot, so when sharing a database across instances, keep their versions matched and roll one at a time.

**Private / pre-release images.** The image defaults to the public `ghcr.io/broch-io/broch` — a normal deploy needs nothing. To run a private pre-release/beta image you've been granted, set `brochImage` and `registryPassword` (the `registryServer`/`registryUsername` default to GHCR, so the token is usually all you supply); the template logs in on the VM before pulling.

## Taking over an existing database

Pointing this VM at a database another Broch instance already uses is a **migration, not a test**:

- **One instance per database.** Broch does not cluster — don't run two instances against the same DB at once. Stop the other first.
- **Version match.** A different image version migrates the schema on boot; pin `brochVersion` to the version the other instance runs.
- **Master key must match** — a fresh key cannot decrypt stored state.
- **Back up** the database + master key, and validate against a restored copy first.

## Teardown

In **Existing/Managed** mode the VM holds no state — the database is separate, so the box is disposable (back up the DB + master key, not the VM). **In `databaseMode=Local`, the dedicated `<vmName>-data` disk holds your entire database** — a separate resource that deliberately survives VM deletion, so teardown must treat it as the thing to preserve (and the disk-cleanup step below deliberately excludes it).

If you deployed into a **dedicated resource group** and have **no Local database to keep** — Existing/Managed mode, or you have already snapshotted/moved the `<vmName>-data` disk out of the group — teardown is one line:

```sh
az group delete --name <dedicated-rg> --yes
```

> ⚠️ **In `databaseMode=Local`, `az group delete` DESTROYS your database.** It removes *every* resource in the group, **including the `<vmName>-data` disk** — `deleteOption: Detach` only protects the disk when the *VM* is deleted via the VM API, **not** when the enclosing group is deleted. To keep a Local database, do **not** use `az group delete`: first snapshot or move the `<vmName>-data` disk out of the group (see [Local database](#local-database)), or delete resources individually with the `-data`-excluding filter below.

**If the VM shares a resource group with your database** (or anything else you want to keep), do **not** delete the group — it takes the DB with it. Delete only this deployment's resources (default `vmName` is `broch`):

```sh
RG=broch-rg VM=broch
az vm delete         -g $RG -n $VM --yes
az network nic delete        -g $RG -n $VM-nic
az network public-ip delete  -g $RG -n $VM-pip
az network vnet delete       -g $RG -n $VM-vnet
az network nsg delete        -g $RG -n $VM-nsg
# az vm delete leaves the OS disk — remove it too. The `!ends_with(...,'-data')` filter EXCLUDES the
# Local-mode data disk so a teardown never silently destroys your database (starts_with('broch-data',
# 'broch') would otherwise match it). In Local mode, delete the DB explicitly only when you truly want
# it gone:  az disk delete -g $RG -n $VM-data --yes
# Build the query in a variable with `!` SINGLE-quoted: in an interactive shell (history-expansion on by
# default) a double-quoted `!ends_with` is taken as a history event -> `bash: !ends_with: event not found`
# and the filter never runs. Single quotes around the `!` segment suppress that; $VM still expands.
Q='[?starts_with(name, '"'$VM'"') && !ends_with(name, '"'-data'"')].id'
az disk list -g $RG --query "$Q" -o tsv | xargs -r az disk delete --yes --ids
```

> **Key Vault soft-delete.** The deployment creates a Key Vault for the app secrets (`<vmName>-app-<id>`), **plus a second one for the break-glass password** (`<vmName>-bg-<id>`) in no-SSH-key mode — both deterministic (the `keyVaultName` / `breakGlassKeyVaultName` outputs). (Upgrading from the old single-vault template? Its `<vmName>-kv-<hash>` vault is left orphaned — delete it separately; see [Secrets & break-glass](#secrets--break-glass).) After a teardown that removes a vault, it stays **soft-deleted for 7 days**, and a fresh deployment into a recreated **same-name, same-region** resource group derives the same vault names and fails with *"A vault with the same name already exists in deleted state"* — set **`recoverSoftDeletedVaults=true`** on that deployment and it recovers the vaults and proceeds (you supply exactly the same fields either way; supplied values overwrite the recovered secrets). Recreating the group in a **different region** derives fresh vault names (they are salted with the region) — no collision, leave the flag false, and the old ghosts expire on their own. Keep the **same auth mode** (password vs SSH key) as the deleted deployment: an SSH-key deployment created no break-glass vault, so recreating it in password mode with the flag set tries to recover a break-glass vault that never existed and fails loudly — switching modes needs a fresh group name or a purge. The flag is idempotent — over a live vault the recover pre-pass is a no-op — so a Redeploy retry that carries it over from a recovery deployment is safe; it only fails when no vault of the name exists in any state. Why the flag exists at all: Azure silently auto-recovers a soft-deleted vault on a plain PUT **only when the request matches the vault's state at deletion** — the break-glass vault (RBAC, constant properties) usually passes, but the app vault's access policy names the PREVIOUS deployment's VM identity, and every deployment mints a fresh one, so it can never match without an explicit `createMode: recover` pre-pass. Purge protection is deliberately **off** so the names stay reclaimable (`az keyvault purge` remains available if you ever need a name freed early, e.g. after switching auth modes under the same group name).
