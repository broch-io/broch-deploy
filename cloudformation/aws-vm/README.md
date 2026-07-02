# AWS VM — CloudFormation template

Broch on a single **EC2 instance**, deployed with CloudFormation. The AWS analog of [`bicep/azure-vm`](../../bicep/azure-vm/) — it runs the canonical [`with-postgres-external` + Caddy compose stack](../../docker-compose/with-postgres-external/) **verbatim** (UserData base64-embeds it at build time, so the box runs the same bytes as a docker-direct deploy).

**The friction win:** wildcard TLS via Caddy ACME DNS-01, issued with the **instance's IAM role** against Route 53 — no token typed, no cert upload, and (unlike the Azure managed-identity path) **no post-deploy role grant**, because the stack creates the zone-scoped role itself.

**Bring your own domain** (in Route 53) and an IdP. That's it.

## What this provisions

```text
                          ┌────────────────────────────────────┐
internet ─ 80/443/443udp ─▶ EC2 instance — Elastic IP, SG       │
                          │   caddy — wildcard TLS, ACME DNS-01 │
                          │     ↳ instance IAM role → Route 53  │
                          │     ↳ HTTP ─▶ broch (8080, internal)│
                          └──────────────────┬──────────────────┘
                                             │ TCP:5432 (SSL)
                                             ▼
                          ╔════════════════════════════════════╗
                          ║ RDS Postgres (NewServer) or your    ║
                          ║ existing DB (ExistingDatabase)      ║
                          ╚════════════════════════════════════╝
```

- An Ubuntu 24.04 EC2 instance (default `t4g.small`, ARM64; the broch image is multi-arch). AMI resolved from SSM, so no per-region AMI table.
- An **Elastic IP** — the stable address the A records point at, kept across instance replacement.
- A security group: HTTP (80) + HTTPS/HTTP-3 (443 tcp+udp) from the internet. SSH (22) is **closed by default**; set `SshAllowedCidr` for break-glass, or use **SSM Session Manager** (no SSH).
- An **instance IAM role**: Route 53 (scoped to your zone) for DNS-01, read-only on the secrets this stack generates, and `AmazonSSMManagedInstanceCore` for break-glass.
- `NewServer`: a private, encrypted **RDS Postgres** reachable only from the instance SG; its password is generated into Secrets Manager.
- Your **`BROCH_MASTER_KEY`** (the required `BrochMasterKey` parameter) stashed in Secrets Manager so the instance can read it at boot — customer-supplied, never generated, never seen by Broch.
- With `DnsProvider=Route53` (the default): apex + wildcard **A records** in your hosted zone, pointing at the Elastic IP — created with the stack, deleted with it. With the other DNS providers your zone lives outside Route 53, so point the apex + wildcard A records at the `PublicIp` output yourself.

License and telemetry are configured **in-app** (Admin UI) after first sign-in — not at deploy.

## Prerequisites

- AWS credentials that can create EC2 / IAM / RDS / Route 53 / Secrets Manager / EIP.
- A **Route 53 hosted zone** for your wildcard hostname's domain. DNS-01 (the instance role) and the A records both use it. If your DNS is elsewhere, either delegate a subdomain to Route 53, or set `DnsProvider=Cloudflare` and supply a token.
- An **identity provider** app (Auth0, Entra ID, Okta, or any OIDC) — Broch has no local login. Register the callback `https://<WildcardHostname>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in. Buy at [broch.io/pricing](https://broch.io/pricing).

## Build & deploy

The committed `template.yaml` carries `__*_B64__` placeholders (the compose file, both Caddyfiles, and the per-provider TLS fragments). `build.sh` embeds the canonical assets and writes the deployable `dist/template.yaml`:

```sh
./build.sh

# Generate the master key ONCE, store it in your own secret manager, and reuse the
# SAME value on every redeploy that reuses the database (a fresh key can't decrypt
# existing data). For a first deploy:
export BROCH_MASTER_KEY="$(openssl rand -base64 48)"

aws cloudformation deploy \
  --template-file dist/template.yaml \
  --stack-name broch \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      BrochMasterKey="$BROCH_MASTER_KEY" \
      WildcardHostname=tunnels.example.com \
      HostedZoneId=Z0123456789ABCDEFGHIJ \
      AcmeEmail=ops@example.com \
      DbSubnetIds=subnet-aaaa\\,subnet-bbbb \
      VpcId=vpc-0123456789abcdef0 \
      InstanceSubnetId=subnet-aaaa \
      AuthProvider=Auth0 AuthClientId=... AuthClientSecret=... \
      AuthDomain=your-tenant.auth0.com

# URL + where the master key landed:
aws cloudformation describe-stacks --stack-name broch \
  --query "Stacks[0].Outputs" --output table
```

`broch.example.params.json` is a ready-to-edit parameter file for `--parameters file://...` in `create-stack`. (For a console-based deploy, upload `dist/template.yaml` to an S3 bucket and open it via a CloudFormation "Launch Stack" URL.)

> **The master key is yours.** `BrochMasterKey` is **required** and customer-supplied — Broch never generates or sees it. It's stashed in Secrets Manager (`<stack>/broch-master-key`) in your account only so the instance can read it at boot. Keep the original safe and supply the **same** value on any redeploy that reuses the database (a fresh key can't decrypt existing data).

## Database modes

- **`NewServer`** (default) — provisions the private RDS above. Broch connects as the RDS master to a `brochdb` database.
- **`ExistingDatabase`** — set `DatabaseConnectionString` to a ready Npgsql string; the stack creates no database.
- **`ExistingServer`** — reuse a Postgres server you already run. Supply `DbServerHost`, `DbServerPort` (default 5432), `DbAdminUsername`, `DbAdminPassword`, and `DbServerSecurityGroupId`. The stack opens Postgres on that SG to this instance and, at boot, uses the admin creds **once** to carve a `brochdb` database + a least-privilege `broch` role (generated password in Secrets Manager, PG15+ `public`-schema owner grant) — idempotent, and it never touches the server's other databases. The admin password is fetched only for the carve and is not written to the instance's `.env`. **Prerequisites:** the instance must be able to reach the server (same VPC or peered/routable), and `DbAdminUsername` must be a role that can `CREATE ROLE`/`CREATE DATABASE` (e.g. the RDS master / `rds_superuser`).

## TLS

Two modes, set by `CertMode`:

- **`Auto`** (default) — Caddy auto-issues and renews the wildcard via ACME DNS-01. Pick a `DnsProvider`:
  - **`Route53`** (default) — needs **no secret**; Caddy's `route53` module authenticates with the instance role (the `.env` sets no AWS keys, so it falls through to instance-metadata credentials).
  - **`Cloudflare`** — set `CloudflareApiToken` (Zone:Read + DNS:Edit).
  - **`GoogleCloudDns`** — set `GcpProject` + `GcpCredentialsJson` (base64 SA JSON, `roles/dns.admin`).
  - **`DigitalOcean`** — set `DoAuthToken` (DNS write scope).

  With the non-Route53 providers the stack cannot create records in your zone — after deploy, point the apex + wildcard A records at the `PublicIp` output (DNS-only / grey-cloud on Cloudflare). Issuance itself doesn't wait on them: DNS-01 is TXT-based, so the cert is typically ready before you cut DNS over.
- **`Byo`** — supply your own wildcard cert + key: set `TlsCertificate` and `TlsCertificateKey` (both base64 PEM, e.g. `base64 -w0 fullchain.pem`). No ACME, no `DnsProvider`; **renewal is your responsibility** (replace the secret + redeploy, or swap the files on the instance and `caddy reload`).

Every credential above is stashed in Secrets Manager and fetched at boot via the instance role — none ride in UserData. Mis-set combinations (Cloudflare/DigitalOcean without a token, GoogleCloudDns without creds, Byo without cert+key, NewServer without subnets) **fail fast** at stack create via template `Rules`, before any resource is built.

After deploy, watch issuance over SSM:

```sh
aws ssm start-session --target <instance-id>
sudo docker compose -f /opt/broch/docker-compose.yml logs -f caddy
```

Then sign in at `https://<WildcardHostname>`.

## Teardown

```sh
aws cloudformation delete-stack --stack-name broch
```

The RDS instance is created with a `Snapshot` deletion policy — a final snapshot is taken on delete (`ExistingDatabase` deployments leave your DB untouched). Record the master key before deleting if you intend to redeploy against the same data.

## Status

The template is lint-validated (`cfn-lint`) and the appliance boot path is exercised end-to-end
(create → boot-to-healthy → teardown). Before relying on it in production, validate the specific
configuration you intend to run in a non-production account — in particular the automatic-certificate
path for your `DnsProvider` (including the default Route 53 instance-role DNS-01) and the
`ExistingDatabase` / `ExistingServer` database modes.
