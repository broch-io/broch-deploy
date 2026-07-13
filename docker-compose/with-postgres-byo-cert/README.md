# with-postgres-byo-cert docker-compose

Variant of [`../with-postgres/`](../with-postgres/) that uses a **bring-your-own (BYO) wildcard certificate** instead of Caddy's automatic ACME issuance. Same broch + Postgres + Caddy shape, but you provide the cert files and own the renewal cadence.

Use this when:
- Your DNS provider isn't [supported by Caddy's DNS modules](https://github.com/caddy-dns) and you can't (or don't want to) compile a custom build
- Your team has central cert management — purchased from a commercial CA, issued from internal PKI, rotated by your security team's automation
- You're in an air-gapped or restricted-egress network where Caddy can't reach Let's Encrypt during issuance
- You already have a wildcard cert from certbot (or any other source) and just want Caddy to serve it

For ACME automation with a supported DNS provider, use [`../with-postgres/`](../with-postgres/) instead.

## Architecture

Same as [`../with-postgres/`](../with-postgres/) — only the cert source changes:

```
                  ┌──────────────────────────────────────────┐
internet ──────▶  │ caddy (80/443/443udp)                    │
                  │   ↳ serves ./certs/fullchain.pem + key   │
                  │   ↳ NO ACME, NO renewal — that's on you  │
                  └────────────────┬─────────────────────────┘
                                   │ HTTP
                  ┌────────────────▼─────────────────────────┐
                  │ broch (8080, internal only)              │
                  └────────────────┬─────────────────────────┘
                                   │
                  ┌────────────────▼─────────────────────────┐
                  │ postgres:17-alpine                        │
                  └──────────────────────────────────────────┘
```

## Prerequisites

- Docker 24+ with `docker compose` v2
- A wildcard cert + key pair in PEM format covering BOTH:
  - The apex hostname (e.g. `broch.example.com`)
  - The wildcard (`*.broch.example.com`)
  - One cert with both as SANs is typical; two separate certs also works but requires Caddyfile edits
- Routine to refresh those files before expiry (see [Renewal](#renewal))
- An identity provider (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so you configure your IdP at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- DNS A/AAAA record for the apex hostname pointing at this host's public IP
- Optional: a Broch license — activated in-app after first sign-in (Admin → License). Buy at [broch.io/pricing](https://broch.io/pricing).

## Setup

```sh
# 1. Drop your cert files (PEM format)
mkdir -p certs
cp /path/to/your/fullchain.pem  ./certs/fullchain.pem
cp /path/to/your/privkey.pem    ./certs/privkey.pem
chmod 644 ./certs/fullchain.pem
chmod 600 ./certs/privkey.pem

# 2. Copy + fill the env template
cp .env.example .env
$EDITOR .env   # BROCH_MASTER_KEY, BROCH_WILDCARD_HOSTNAME, AUTHENTICATION__*, POSTGRES_PASSWORD

# 3. Start
docker compose up -d

# 4. Verify (give Postgres a minute on first run)
docker compose ps
curl -fsS https://broch.example.com/healthz
```

## Renewal

**Caddy does NOT renew these certs.** It serves whatever is at `./certs/fullchain.pem` and `./certs/privkey.pem`.

Set up your own renewal pipeline:

```sh
# certbot example — run as a cron job a few times a week
certbot certonly --dns-<your-provider> \
  -d 'broch.example.com' -d '*.broch.example.com' \
  --deploy-hook "cp /etc/letsencrypt/live/broch.example.com/fullchain.pem \
                    $(pwd)/certs/fullchain.pem && \
                 cp /etc/letsencrypt/live/broch.example.com/privkey.pem \
                    $(pwd)/certs/privkey.pem && \
                 docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile"
```

The `caddy reload` step is what makes Caddy pick up the new files without restarting (in-place reload, no dropped connections).

**Calendar reminder:** even with automation, set a calendar reminder for cert expiry minus 14 days. If the renewal pipeline silently fails, you want to know before traffic breaks.

## Why `auto_https off` in the Caddyfile?

By default, Caddy tries to auto-issue certs via ACME for any hostname it sees in the Caddyfile. With `auto_https off`, that's disabled and Caddy serves only the cert files you point it at. The Caddyfile also adds an explicit `:80 → :443` redirect block, since `auto_https off` disables that automatic behaviour too.

## Lifecycle

```sh
docker compose up -d                              # Start
docker compose logs -f broch caddy                # Watch logs
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
                                                  # Pick up new cert files
docker compose down                               # Stop, keep DB volume
docker compose down -v                            # Stop, destroy DB volume
```

## Persistence

Recovery-critical state is the Postgres data + `BROCH_MASTER_KEY`: the DataProtection keys stored in Postgres are encrypted under your master key, so a restored database is only readable together with the key from your `.env`. Back up:

- **your `.env`** — holds `BROCH_MASTER_KEY` (and the rest of your configuration)
- **`with-postgres-byo-cert_postgres_data`** — your broch state (users, tunnels, licenses, …)
- **`./certs/`** — your cert + key pair (re-issuable from your CA, but a copy speeds recovery)

Example backup:

```sh
cp .env broch-env-$(date +%Y%m%d).backup   # store somewhere safe — it contains secrets
docker run --rm \
  -v with-postgres-byo-cert_postgres_data:/data/postgres \
  -v "$PWD":/backup \
  alpine \
  tar czf /backup/broch-state-$(date +%Y%m%d).tar.gz -C /data .
```

## When to graduate from this example

If your wildcard cert source supports a Caddy DNS module (Cloudflare, Route 53, Google Cloud DNS, Gandi, DigitalOcean, Hetzner, etc.), switch to [`../with-postgres/`](../with-postgres/) — automatic issuance + renewal in-stack, no cron jobs to maintain.

If you also want managed Postgres + load balancing, the [`../../terraform/aws-ecs/`](../../terraform/aws-ecs/) and [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/) modules handle the cert side via ACM / Azure-managed certs respectively — you don't carry the renewal burden.
