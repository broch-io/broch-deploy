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
- A registered domain on **Cloudflare** (Azure DNS, Route 53, Google Cloud DNS and DigitalOcean work too — see [Using a different DNS provider](#using-a-different-dns-provider))
- A Cloudflare API token scoped to that zone with **Zone:Read + DNS:Edit** — create one at <https://dash.cloudflare.com/profile/api-tokens> using the "Edit zone DNS" template
- An identity provider (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so you configure your IdP at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/). Auth0 also needs an **API** (its Identifier is `AUTHENTICATION__AUDIENCE`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it.
- Optional: a Broch license — activated in-app after first sign-in (Admin → License). Buy at <https://broch.io/pricing>

## DNS records

In your Cloudflare zone, create records for the hostname **and** its wildcard. Every tunnel URL is `<name>.broch.example.com`, and a wildcard record doesn't cover its own bare name:

```text
A     broch.example.com      →  <your-VM-public-IPv4>
A     *.broch.example.com    →  <your-VM-public-IPv4>
AAAA  broch.example.com      →  <your-VM-public-IPv6>    (if available)
AAAA  *.broch.example.com    →  <your-VM-public-IPv6>    (if available)
```

These records are for resolution only; you create none for the certificate. Caddy uses DNS-01 to prove zone control and Let's Encrypt issues the wildcard from there. To have Caddy create and maintain the A records with the same token, see [`dynamic-dns.caddy`](dynamic-dns.caddy).

> **Cloudflare proxy ("orange cloud"):** turn it **OFF** for these records. Caddy needs to receive the real client IPs, and the DNS-01 challenge needs to reach Cloudflare's DNS API not the proxy edge. The orange cloud also re-encrypts with its own cert, which conflicts with Caddy's TLS.

## Setup

```sh
# 1. Copy + fill the env template
cp .env.example .env
$EDITOR .env

# 2. Pull broch, postgres and broch-caddy (Caddy with the DNS-01 modules) + start
docker compose up -d

# 3. Watch the logs while Caddy provisions certs (first run takes ~30-60s)
docker compose logs -f caddy

# 4. Once you see "certificate obtained successfully", verify the endpoint
curl -fsS https://broch.example.com/healthz
```

## What's required in `.env`

| Variable                  | What it is                                                        |
| ------------------------- | ----------------------------------------------------------------- |
| `BROCH_MASTER_KEY`        | At-rest encryption root. Server won't start without it — `openssl rand -base64 48`. |
| `BROCH_WILDCARD_HOSTNAME` | Your real DNS name. It and its wildcard (`*.broch.example.com`) must resolve to this host's public IP (see [DNS records](#dns-records)). |
| `CADDY_ACME_EMAIL`        | Let's Encrypt account contact. Compose won't start while blank.   |
| `CLOUDFLARE_API_TOKEN`    | For the default Cloudflare provider: a Zone:Read + DNS:Edit token for the zone hosting your hostname. Another provider uses its own variables instead (see [Using a different DNS provider](#using-a-different-dns-provider)). |
| `POSTGRES_PASSWORD`       | Strong password for the bundled Postgres. No `;` or `"`, and no leading or trailing space (it goes unquoted into Broch's connection string). |
| `AUTHENTICATION__*`       | Your identity provider — part of the boot floor. No one can sign in until it's set. |

A Broch license is activated in-app on first sign-in (Admin → License) — there's no env var for it.

## Lifecycle

```sh
# Start
docker compose up -d

# Refresh the broch-caddy image (it tracks :latest; `up -d` alone keeps the copy you have)
docker compose pull caddy
docker compose up -d

# Logs
docker compose logs -f broch caddy

# Stop, keeping data
docker compose down

# Apply an edit to Caddyfile or tls.caddy. Recreate rather than reload: each is a single-file
# mount, so an editor that saves by renaming leaves the running container on the old file.
docker compose up -d --force-recreate caddy
```

## Upgrading

1. Back up first — Postgres data plus your `.env` (see [Persistence](#persistence)).
2. Set an explicit `BROCH_VERSION` in `.env` so the version you run is the version you chose. Upgrades migrate the database forward, so going back to an older version means restoring the backup from step 1, not just changing this line:

   ```sh
   BROCH_VERSION=<version>
   ```

3. **Auth0 only:** make sure `.env` sets `AUTHENTICATION__AUDIENCE` to the Identifier of your Auth0 API. Broch 1.34.0 and later refuse to start as Auth0 without it, and they check only after migrating the database, so an upgrade without it leaves you with a migrated database and a server that won't start.
4. Pull and restart:

   ```sh
   docker compose pull broch
   docker compose up -d
   ```

Release notes and version-specific steps: <https://broch.io/docs/self-hosting/upgrading/>

## Persistence

Recovery-critical state is the Postgres data + `BROCH_MASTER_KEY`: the DataProtection keys stored in Postgres are encrypted under your master key, so a restored database is only readable together with the key from your `.env`. Back up:

- **your `.env`** — holds `BROCH_MASTER_KEY` and `POSTGRES_PASSWORD` (and the rest of your configuration)
- **the database** — your broch state (users, tunnels, licenses, …), as a `pg_dump`
- **`with-postgres_caddy_data`** — Caddy's ACME account + issued certs. If you lose this, Let's Encrypt rate-limits new issuance to 5/week per hostname; you don't want to hit that during recovery.

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

A copy of the volumes (`with-postgres_postgres_data`, `with-postgres_caddy_data`) also works, but only with the stack stopped: a copy of a running Postgres data directory may not restore. The names are `<project>_postgres_data` and `<project>_caddy_data`, where `<project>` is this directory's name, or `COMPOSE_PROJECT_NAME` if your `.env` sets it. Check them with `docker volume ls` first and adjust the commands: given a name that doesn't exist, `docker run -v` creates an empty volume and archives that.

```sh
docker compose down
docker run --rm \
  -v with-postgres_postgres_data:/data/postgres \
  -v with-postgres_caddy_data:/data/caddy \
  -v "$PWD":/backup \
  alpine \
  tar czf /backup/broch-volumes-$(date +%Y%m%d).tar.gz -C /data .
docker compose up -d
```

## Using a different DNS provider

The broch-caddy image has the Cloudflare, Azure DNS, Route 53, Google Cloud DNS and DigitalOcean modules compiled in, and `docker-compose.yml` already passes each one's credentials through to Caddy, so switching is an edit, not a rebuild. To swap from Cloudflare to, say, AWS Route 53:

1. Edit [`tls.caddy`](tls.caddy): replace the active `tls { dns cloudflare … }` block with the provider's block from [`../caddy-tls/`](../caddy-tls/) (here [`route53.caddy`](../caddy-tls/route53.caddy)). `tls.caddy` also carries each one as a commented example.
2. Set that provider's credentials in `.env` (here `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`; [`.env.example`](.env.example) lists each provider's) and leave the others empty.
3. `docker compose up -d --force-recreate caddy` — the new container reads both the new `.env` values and `tls.caddy`.

For a provider the image lacks, comment out `image:` and uncomment `build:` under `caddy` in `docker-compose.yml`, add the module to [`Caddy.Dockerfile`](Caddy.Dockerfile), pass its variables through in `caddy.environment:`, then `docker compose up -d --build`.

## When to graduate from this example

Move to one of the Terraform modules ([`../../terraform/aws-ecs/`](../../terraform/aws-ecs/), [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/), both beta) when you need:

- Managed Postgres with automated backups
- Secrets in a key vault instead of a `.env` file on disk

They don't add availability on their own: Broch still runs as one replica, and the database is single-zone by default.

This single-VM compose handles real production workloads up to the point where Postgres-on-the-same-VM becomes your bottleneck, which is further out than most self-hosters need to worry about.
