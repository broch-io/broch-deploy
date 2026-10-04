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
- An identity provider (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so you configure your IdP at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `AUTHENTICATION__AUDIENCE`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it.
- DNS A/AAAA records for the hostname **and** its wildcard (`broch.example.com` and `*.broch.example.com`; every tunnel URL is `<name>.broch.example.com`) pointing at this host's public IP
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
# certbot example. Issue once, with a deploy hook that copies each renewed pair into this
# directory and reloads Caddy. The hook runs from cron or certbot's timer, not from here,
# so give it absolute paths (replace /path/to/with-postgres-byo-cert with this directory).
certbot certonly --dns-<your-provider> \
  -d 'broch.example.com' -d '*.broch.example.com' \
  --deploy-hook 'cp /etc/letsencrypt/live/broch.example.com/fullchain.pem /path/to/with-postgres-byo-cert/certs/fullchain.pem &&
    cp /etc/letsencrypt/live/broch.example.com/privkey.pem /path/to/with-postgres-byo-cert/certs/privkey.pem &&
    docker compose --project-directory /path/to/with-postgres-byo-cert exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force'

# Renewal: schedule this, e.g. from cron twice a day (a packaged certbot already runs it
# from a timer). It reuses the saved deploy hook for each certificate it renews.
certbot renew
```

The `caddy reload --force` step is what makes Caddy pick up the new files without restarting (in-place reload, no dropped connections). Without `--force`, Caddy sees an unchanged config and skips the reload, so it keeps serving the old certificate.

The two files are mounted one by one, so overwrite them in place (`cp` or `cat >`, as above). A tool that replaces a file by renaming it (`mv`, `install`, Ansible's `copy`) leaves the container on the old file, and the reload picks up the old certificate again. After one of those, recreate Caddy instead: `docker compose up -d --force-recreate caddy`.

**Calendar reminder:** even with automation, set a calendar reminder for cert expiry minus 14 days. If the renewal pipeline silently fails, you want to know before traffic breaks.

## Why `auto_https off` in the Caddyfile?

By default, Caddy tries to auto-issue certs via ACME for any hostname it sees in the Caddyfile. With `auto_https off`, that's disabled and Caddy serves only the cert files you point it at. The Caddyfile also adds an explicit `:80 → :443` redirect block, since `auto_https off` disables that automatic behaviour too.

## Lifecycle

```sh
docker compose up -d                              # Start
docker compose logs -f broch caddy                # Watch logs
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --force
                                                  # Pick up new cert files
docker compose down                               # Stop, keep DB volume
docker compose down -v                            # Stop, destroy DB volume
```

**Upgrading with Auth0:** make sure `.env` sets `AUTHENTICATION__AUDIENCE` to the Identifier of your Auth0 API before you pull a new image. Broch 1.34.0 and later refuse to start as Auth0 without it, and they check only after migrating the database, so an upgrade without it leaves you with a migrated database and a server that won't start.

## Persistence

Recovery-critical state is the Postgres data + `BROCH_MASTER_KEY`: the DataProtection keys stored in Postgres are encrypted under your master key, so a restored database is only readable together with the key from your `.env`. Back up:

- **your `.env`** — holds `BROCH_MASTER_KEY` and `POSTGRES_PASSWORD` (and the rest of your configuration)
- **the database** — your broch state (users, tunnels, licenses, …), as a `pg_dump`
- **`./certs/`** — your cert + key pair (re-issuable from your CA, but a copy speeds recovery)

Example backup, run in this directory (the commands use the default `POSTGRES_USER` `broch` and `POSTGRES_DB` `brochdb`; use yours if you changed them):

```sh
cp .env broch-env-$(date +%Y%m%d).backup   # store somewhere safe — it contains secrets
docker compose exec -T postgres pg_dump -U broch brochdb > broch-db-$(date +%Y%m%d).sql
```

Restore, for example to roll back an upgrade:

```sh
docker compose stop broch
docker compose exec -T postgres dropdb -U broch brochdb
docker compose exec -T postgres createdb -U broch -O broch brochdb
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U broch -d brochdb < broch-db-<date>.sql
$EDITOR .env                  # set BROCH_VERSION back to the backup's version
docker compose up -d
```

On a fresh host, put the `.env` backup in place first and start only Postgres (`docker compose up -d --wait postgres`, which returns once it's ready) instead of stopping broch, then run the rest.

A copy of the `with-postgres-byo-cert_postgres_data` volume also works, but only with the stack stopped: a copy of a running Postgres data directory may not restore. The name is `<project>_postgres_data`, where `<project>` is this directory's name, or `COMPOSE_PROJECT_NAME` if your `.env` sets it. Check it with `docker volume ls` first and adjust the command: given a name that doesn't exist, `docker run -v` creates an empty volume and archives that.

```sh
docker compose down
docker run --rm \
  -v with-postgres-byo-cert_postgres_data:/data/postgres \
  -v "$PWD":/backup \
  alpine \
  tar czf /backup/broch-volumes-$(date +%Y%m%d).tar.gz -C /data .
docker compose up -d
```

## When to graduate from this example

If your DNS is on Cloudflare, Azure DNS, Route 53, Google Cloud DNS or DigitalOcean, switch to [`../with-postgres/`](../with-postgres/) — its broch-caddy image issues and renews the wildcard in-stack, no cron jobs to maintain. Another [caddy-dns](https://github.com/caddy-dns) provider works there too, with a custom build from its `Caddy.Dockerfile`.

If you also want managed Postgres, the Terraform modules (both beta) provision it. [`../../terraform/aws-ecs/`](../../terraform/aws-ecs/) also gets the wildcard from ACM, which renews it for you. [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/) still needs a wildcard certificate you provide and renew: Container Apps' managed certificates don't cover wildcards.
