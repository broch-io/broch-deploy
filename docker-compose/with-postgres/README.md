# with-postgres + Caddy docker-compose

Production-shape Broch on a single VM: server + bundled Postgres + Caddy as a reverse proxy with automatic Let's Encrypt TLS, including the wildcard cert for tunnel subdomains. This is what most self-hosters want.

## Architecture

```
                  ┌──────────────────────────────────────────┐
internet ──────▶  │ caddy (80/443/443udp)                    │
                  │   ↳ TLS for broch.example.com (apex)     │
                  │   ↳ TLS for *.broch.example.com (wild)   │
                  │   ↳ ACME DNS-01 via Cloudflare           │
                  └────────────────┬─────────────────────────┘
                                   │ HTTP
                  ┌────────────────▼─────────────────────────┐
                  │ broch (8080, internal only)              │
                  └────────────────┬─────────────────────────┘
                                   │
                  ┌────────────────▼─────────────────────────┐
                  │ postgres (5432, internal only)           │
                  │   ↳ named volume: postgres_data          │
                  └──────────────────────────────────────────┘
```

Only Caddy is reachable from outside the host. Broch and Postgres are on a private docker network.

## Prerequisites

- Docker 24+ with the `docker compose` v2 plugin
- A VM with public IPs (v4 and ideally v6) and ports 80 / 443 open
- A registered domain on **Cloudflare** (if you use a different DNS provider, see [Caddy.Dockerfile](Caddy.Dockerfile) — Caddy supports route53, googleclouddns, gandi, digitalocean, hetzner, and more)
- A Cloudflare API token scoped to that zone with **Zone:Read + DNS:Edit** — create one at <https://dash.cloudflare.com/profile/api-tokens> using the "Edit zone DNS" template
- An identity provider (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so you configure your IdP at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- Optional: a Broch license — activated in-app after first sign-in (Admin → License). Buy at <https://broch.io/pricing>

## DNS records

In your Cloudflare zone, create:

```
A     broch.example.com    →  <your-VM-public-IPv4>
AAAA  broch.example.com    →  <your-VM-public-IPv6>    (if available)
```

You do **not** need to pre-create wildcard records — Caddy uses DNS-01 to prove zone control and Let's Encrypt issues the wildcard from there. The wildcard subdomains resolve via your apex routing, not via DNS.

> **Cloudflare proxy ("orange cloud"):** turn it **OFF** for the apex record. Caddy needs to receive the real client IPs, and the DNS-01 challenge needs to reach Cloudflare's DNS API not the proxy edge. The orange cloud also re-encrypts with its own cert, which conflicts with Caddy's TLS.

## Setup

```sh
# 1. Copy + fill the env template
cp .env.example .env
$EDITOR .env

# 2. Build the custom Caddy image (with Cloudflare-DNS module) + pull broch/postgres + start
docker compose up -d --build

# 3. Watch the logs while Caddy provisions certs (first run takes ~30-60s)
docker compose logs -f caddy

# 4. Once you see "certificate obtained successfully", verify the endpoint
curl -fsS https://broch.example.com/healthz
```

## What's required in `.env`

| Variable                  | What it is                                                        |
| ------------------------- | ----------------------------------------------------------------- |
| `BROCH_MASTER_KEY`        | At-rest encryption root. Server won't start without it — `openssl rand -base64 48`. |
| `BROCH_WILDCARD_HOSTNAME` | Your real DNS name. Must resolve to this host's public IP.        |
| `CADDY_ACME_EMAIL`        | Where Let's Encrypt sends cert-expiry warnings. Use a real inbox. |
| `CLOUDFLARE_API_TOKEN`    | Zone:Read + DNS:Edit token for the zone hosting your hostname.    |
| `POSTGRES_PASSWORD`       | Strong password for the bundled Postgres.                         |
| `AUTHENTICATION__*`       | Your identity provider — part of the boot floor. No one can sign in until it's set. |

A Broch license is activated in-app on first sign-in (Admin → License) — there's no env var for it.

## Lifecycle

```sh
# Start
docker compose up -d --build      # --build keeps the Caddy image fresh

# Logs
docker compose logs -f broch caddy

# Stop, keeping data
docker compose down

# Renew Caddy after editing Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Upgrading

1. Back up first — Postgres data plus your `.env` (see [Persistence](#persistence)).
2. Set an explicit `BROCH_VERSION` in `.env` so the version you run is the version you chose (and rollback is a one-line change):

   ```sh
   BROCH_VERSION=1.23.0
   ```

3. Pull and restart:

   ```sh
   docker compose pull broch
   docker compose up -d
   ```

Release notes and version-specific steps: <https://broch.io/docs/self-hosting/upgrading/>

## Persistence

Recovery-critical state is the Postgres data + `BROCH_MASTER_KEY`: the DataProtection keys stored in Postgres are encrypted under your master key, so a restored database is only readable together with the key from your `.env`. Back up:

- **your `.env`** — holds `BROCH_MASTER_KEY` (and the rest of your configuration)
- **`with-postgres_postgres_data`** — your broch state (users, tunnels, licenses, …)
- **`with-postgres_caddy_data`** — Caddy's ACME account + issued certs. If you lose this, Let's Encrypt rate-limits new issuance to 5/week per hostname; you don't want to hit that during recovery.

Example backup:

```sh
cp .env broch-env-$(date +%Y%m%d).backup   # store somewhere safe — it contains secrets
docker run --rm \
  -v with-postgres_postgres_data:/data/postgres \
  -v with-postgres_caddy_data:/data/caddy \
  -v "$PWD":/backup \
  alpine \
  tar czf /backup/broch-state-$(date +%Y%m%d).tar.gz -C /data .
```

## Using a different DNS provider

Caddy supports many providers, but each one needs its module compiled into the Caddy binary. To swap from Cloudflare to, say, AWS Route53:

1. Edit [`Caddy.Dockerfile`](Caddy.Dockerfile): change `github.com/caddy-dns/cloudflare` to `github.com/caddy-dns/route53`
2. Edit [`Caddyfile`](Caddyfile): change both `dns cloudflare {env.CLOUDFLARE_API_TOKEN}` lines to use the route53 module's config (see the module's README at <https://github.com/caddy-dns/route53>)
3. Update `.env` with the credentials your provider needs (e.g. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)
4. Update `docker-compose.yml`'s `caddy.environment:` block to pass those vars through
5. `docker compose up -d --build` to rebuild Caddy

## When to graduate from this example

Move to one of the Terraform examples ([`../../terraform/aws-ecs/`](../../terraform/aws-ecs/), [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/)) when you need:

- Managed Postgres with backups + read replicas
- A load balancer in front of broch for zero-downtime deploys or horizontal scale
- Secrets in a key vault instead of a `.env` file on disk
- Multi-AZ availability

This single-VM compose handles real production workloads up to the point where Postgres-on-the-same-VM becomes your bottleneck, which is further out than most self-hosters need to worry about.
