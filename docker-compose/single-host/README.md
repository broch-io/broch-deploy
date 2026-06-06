# Single-host docker-compose

Single-VM Broch deployment with no TLS at the broch port — broch + a bundled Postgres on one host, broch exposed directly on `:8080`. Intended for **private networks, internal staging, or developer-laptop use against a hosts-file entry**.

Same dependency footprint as [`../with-postgres/`](../with-postgres/) (broch needs Postgres — it's the only supported database; you also need an identity provider for sign-in, a wildcard hostname, and the GHCR PAT while the image is private; a Broch license is optional at boot). The difference is purely TLS exposure: this example has none, with-postgres adds Caddy + Let's Encrypt for public-internet deployments.

**Don't use this on the public internet.** Tunnel credentials and tunnel traffic would flow over cleartext HTTP. Use [`../with-postgres/`](../with-postgres/) for anything internet-facing.

## What you get

- One `broch` container, image pinned by the `BROCH_VERSION` env var
- One `postgres:17-alpine` container with a durable named volume for state
- Broch's HTTP listener exposed on host `:8080`
- Both containers on a docker-compose default network so they can talk by service name

## Prerequisites

- Docker 24+ and the `docker compose` v2 plugin
- An identity provider (Auth0, Entra ID, Okta, or any OIDC) — Broch has no built-in local login, so you configure your IdP at boot. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A GitHub Personal Access Token with `read:packages` (while the image is private — see the [top-level README](../../README.md#the-broch-server-image))
- A DNS name (or hosts-file entry) for tunnel URLs
- Optional: a Broch license key — activate in-app after first sign-in, or pre-seed it. Buy at [broch.io/pricing](https://broch.io/pricing).

## Setup

```sh
# 1. Log in to GHCR so you can pull the private image (one-time)
echo $GITHUB_PAT | docker login ghcr.io -u <github-user> --password-stdin

# 2. Copy the env template and fill it in
cp .env.example .env
$EDITOR .env   # set BROCH_MASTER_KEY, BROCH_WILDCARD_HOSTNAME, AUTHENTICATION__*, POSTGRES_PASSWORD

# 3. Start the stack
docker compose up -d

# 4. Wait for healthchecks to settle (~60s on first run, postgres init + EF migrations)
docker compose ps

# 5. Verify the server is responding
curl -fsS http://localhost:8080/healthz
```

You should see a `200 OK` from `/healthz` once both services report `healthy`.

## What's required in `.env`

| Variable                  | What it is                                                   |
| ------------------------- | ------------------------------------------------------------ |
| `BROCH_MASTER_KEY`        | At-rest encryption root. Server won't start without it — `openssl rand -base64 48`. |
| `BROCH_WILDCARD_HOSTNAME` | DNS wildcard that tunnel URLs use (e.g. `tunnels.example.com`). |
| `POSTGRES_PASSWORD`       | Strong password for the bundled Postgres — `openssl rand -base64 32`. |
| `AUTHENTICATION__*`       | Your identity provider — part of the boot floor. No one can sign in until it's set. |

`BROCH_LICENSE` is optional at boot — leave it blank and activate in-app on first sign-in, or pre-seed it. Everything else has a sensible default. See [`.env.example`](.env.example) for the full list.

## Connecting a client

Point the Broch CLI at your server:

```sh
broch config set --server http://localhost:8080
broch auth login
```

For non-localhost setups, replace `localhost` with the host's address. Remember: this example doesn't terminate TLS, so anything past localhost flows over cleartext HTTP — fine for private networks, **not** for the public internet.

## Lifecycle

```sh
# Start (detached)
docker compose up -d

# View logs
docker compose logs -f broch

# Stop, keeping data
docker compose down

# Stop and delete the postgres volume (destroys all state)
docker compose down -v

# Pull a newer image and restart
docker compose pull && docker compose up -d
```

## Persistent state

The bundled Postgres writes to a named docker volume `single-host_postgres_data`. To back it up:

```sh
docker run --rm -v single-host_postgres_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/broch-postgres-$(date +%Y%m%d).tar.gz -C /data .
```

For production deployments you should use a managed Postgres (RDS, Azure Database, etc.) — see [`../../terraform/aws-ecs/`](../../terraform/aws-ecs/) and [`../../terraform/azure-container-apps/`](../../terraform/azure-container-apps/) for examples.

## When to graduate from this example

Move to [`../with-postgres/`](../with-postgres/) when you need:

- TLS termination (Let's Encrypt via Caddy)
- A real public DNS hostname instead of `localhost`
- Defense against random internet traffic reaching the broch port directly

Move to a Terraform example when you need:

- Managed Postgres (failover, automated backups, scaling)
- A real load balancer in front of broch
- Secrets in a key vault instead of a `.env` file
- Horizontal scaling or zero-downtime deploys
