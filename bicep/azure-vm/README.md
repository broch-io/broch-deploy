# Azure VM (Bicep)

Broch on a single Azure VM, running the same Docker Compose + Caddy appliance as
the `docker-compose/with-postgres` variant: `broch` + bundled Postgres + Caddy
with automatic wildcard TLS (Let's Encrypt DNS-01). Postgres data lives on a
managed data disk so it survives image upgrades. **Bring your own domain** — you
point DNS at the VM; there's no Broch-managed domain.

This is the VM path for Azure, alongside the [ACA Bicep](../azure-container-apps/).

> **⚠️ DRAFT — not yet validated end-to-end.** This template was ported from the
> [DigitalOcean module](../../terraform/digitalocean/) and compiles (`az bicep
> build`), but has **not** been run on Azure yet. Expect to iterate it against a
> real deployment. It is **not** wired into CI and is **not** a supported path
> until that run-through passes. Treat the device path (`/dev/disk/azure/scsi1/lun0`),
> the Ubuntu image reference, and VM size as the most likely things to adjust.

## What it provisions

- An Ubuntu 24.04 VM (`Standard_B2s` by default) with your SSH key.
- A **static** Standard public IP — the address you point your wildcard DNS at.
- An NSG: SSH (22) from `sshAllowedCidr`, HTTP (80) + HTTPS (443) from the internet.
- A managed **data disk** (LUN 0) for the Postgres data directory.
- cloud-init that writes the compose stack, **generates `BROCH_MASTER_KEY` and the
  Postgres password on the VM at first boot** (they never leave the box), installs
  Docker, mounts the data disk, and starts the stack via systemd.

## Prerequisites

- A domain you control with DNS on **Cloudflare** (or swap the provider — see the
  `Caddy.Dockerfile` block in `cloud-init.yaml`).
- A Cloudflare API token: **Zone:Read + DNS:Edit**, scoped to that zone
  (dashboard → "Edit zone DNS" template).
- An **IdP app** (Auth0 / Entra / Okta / OIDC). Register the callback URL
  **`https://<wildcardHostname>/auth/callback`** in the IdP app **before** you sign
  in, or you'll be bounced at login.
- An Azure resource group, an SSH keypair, and the Azure CLI (`az`).

## Deploy (local-first, by hand)

```bash
# 1. Copy the example params and fill them in (keep real secrets out of git).
cp main.example.bicepparam main.bicepparam
$EDITOR main.bicepparam

# 2. Deploy into a resource group. Pass secrets on the CLI rather than committing.
az group create -n broch-rg -l eastus
az deployment group create \
  -g broch-rg \
  --template-file main.bicep \
  --parameters main.bicepparam \
  --parameters cloudflareApiToken='<token>' authClientSecret='<secret>'

# 3. Note the output IP.
az deployment group show -g broch-rg -n main --query properties.outputs.publicIpAddress.value -o tsv
```

## After deploy

1. **DNS** — create two A records pointing at the output IP, **DNS-only (grey
   cloud)** on Cloudflare (a proxied/orange-cloud record breaks Caddy's TLS and the
   DNS-01 challenge):
   - `wildcardHostname` → IP
   - `*.wildcardHostname` → IP
2. **Wait for TLS** — Caddy builds its image (the swap file covers the one-time
   `xcaddy` compile) and provisions the apex + wildcard certs via DNS-01 (~1–2 min
   after DNS resolves). `ssh` in and `cd /opt/broch && docker compose logs -f caddy`
   to watch.
3. **Sign in** at `https://<wildcardHostname>`, complete first-run setup (buy/trial
   or paste a key), and create your first tunnel.
4. If your reverse proxy weren't on this host you'd set Trusted Proxy CIDRs — here
   Caddy is on the same VM (Docker bridge), so set **Share → Trusted Proxy CIDRs**
   to the Docker bridge range (e.g. `172.16.0.0/12`) if you use IP-based Share
   Network rules. See the [Ingress docs](https://broch.io/docs/self-hosting/ingress/).

## Notes

- **Upgrades:** `ssh` in, `cd /opt/broch`, bump `BROCH_VERSION` in `.env` (pin it!),
  `docker compose pull && docker compose up -d`. Data persists on the data disk.
- **Secrets:** `BROCH_MASTER_KEY` and the Postgres password are generated on the VM
  and live only in `/opt/broch/.env` (mode 0600). Back them up with the Postgres
  data — losing the master key means losing access to encrypted state.
- This is the same appliance Broch's own production is intended to dogfood.
