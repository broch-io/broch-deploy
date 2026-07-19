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
- With `DnsAutoRecords=Auto` (the default): apex + wildcard **A records** pointing at the Elastic IP, created for you — natively on `Route53` (created with the stack, deleted with it), or via `caddy-dynamicdns` on Cloudflare/GoogleCloudDns/DigitalOcean. With `DnsAutoRecords=Manual` (or `CertMode=Byo`), point the apex + wildcard A records at the `PublicIp` output yourself.

License and telemetry are configured **in-app** (Admin UI) after first sign-in — not at deploy.

## Prerequisites

- AWS credentials that can create EC2 / IAM / RDS / Route 53 / Secrets Manager / EIP.
- A **Route 53 hosted zone** for your `DnsZone`. DNS-01 (the instance role) and the A records both use it. If your DNS is elsewhere, either delegate a subdomain to Route 53, or set `DnsProvider=Cloudflare` and supply a token.
- An **identity provider** app (Auth0, Entra ID, Okta, or any OIDC) — Broch has no local login. Register the callback `https://<ShareSubdomain>.<DnsZone>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
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
      DnsZone=example.com \
      ShareSubdomain=broch \
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

> **First boot takes ~3-10 minutes** — instance provisioning, container pulls, DNS propagation, and Let's Encrypt TLS issuance. `https://<ShareSubdomain>.<DnsZone>` will not load until this finishes; that is **expected, not a failed deploy**. `aws cloudformation deploy` blocks until the box reports healthy (the appliance is ready when `https://<host>/healthz` returns `200`), and the stack **rolls back** rather than reporting a false success if boot never goes healthy. The `Readiness` and `DnsHint` stack outputs restate this and the exact A records to create.

> **The master key is yours.** `BrochMasterKey` is **required** and customer-supplied — Broch never generates or sees it. It's stashed in Secrets Manager (`<stack>-<id>/broch-master-key` — the `<id>` is this stack instance's unique CloudFormation id, so a deleted stack's secrets, which linger in Secrets Manager's 30-day deletion window, can never block a redeploy under the same name) in your account only so the instance can read it at boot. Keep the original safe and supply the **same** value on any redeploy that reuses the database (a fresh key can't decrypt existing data).

## Database modes

- **`NewServer`** (default) — provisions the private RDS above. Broch connects as the RDS master to a `brochdb` database.
- **`ExistingDatabase`** — set `DatabaseConnectionString` to a ready Npgsql string; the stack creates no database.
- **`ExistingServer`** — reuse a Postgres server you already run. Supply `DbServerHost`, `DbServerPort` (default 5432), `DbAdminUsername`, `DbAdminPassword`, and `DbServerSecurityGroupId`. The stack opens Postgres on that SG to this instance and, at boot, uses the admin creds **once** to carve a `brochdb` database + a least-privilege `broch` role (generated password in Secrets Manager, PG15+ `public`-schema owner grant) — idempotent, and it never touches the server's other databases. The admin password is fetched only for the carve and is not written to the instance's `.env`. **Prerequisites:** the instance must be able to reach the server (same VPC or peered/routable), and `DbAdminUsername` must be a role that can `CREATE ROLE`/`CREATE DATABASE` (e.g. the RDS master / `rds_superuser`).
- **`Local`** — runs Postgres **on this instance** (the bundled `with-postgres` compose) on a dedicated, encrypted **EBS gp3 data volume** — zero DB prerequisites, deploy → sign in. The volume is mounted at `/var/lib/docker/volumes` before Docker installs, so Postgres's data lives on it. Set **`DataVolumeAz`** to the AZ of `InstanceSubnetId` (**required** — an EBS volume attaches only within its own AZ, and CloudFormation can't derive a subnet's AZ); optionally set `DataVolumeSize` (GiB, default 20) and `LocalDbAdminPassword` (leave empty for a generated password — a supplied one must be letters/digits/`._~-` only, since it is spliced into the DB connection string). **No automated backups / PITR — you own the backups via EBS snapshots** (use `NewServer` for managed backups). The data volume is a separate resource with a `Snapshot` deletion policy, so it survives an instance **stop/start** and a stack **delete** (as a snapshot). To move to a fresh instance, do an explicit **delete + redeploy** — an in-place update that *replaces* the instance is **not** supported (the new instance can't attach the volume the old one still holds). If you redeploy against a snapshot-restored volume, supply the **same** `LocalDbAdminPassword` the data was first initialised with. Postgres keeps the password from first data-dir init, so a redeploy that *generates* a fresh one cannot open the old data — if you never set `LocalDbAdminPassword` (generated password), **read the current value before deleting**: `POSTGRES_PASSWORD` in `/opt/broch/.env` on the instance (via SSM) is always authoritative — it is the password the data directory was initialised with. In Secrets Manager, use the entry that **initialised your data directory** (search by the `broch-local-db-password` suffix): for a stack first deployed on this template version that is the current `<stack>-<id>/broch-local-db-password` entry, but for a deployment **upgraded from an older template version** it is the **retained pre-upgrade entry** (`<stack>/broch-local-db-password`, kept alive through the upgrade precisely for this) — the post-upgrade entry holds a freshly generated value your database has never used. Pass the recovered value explicitly on the redeploy.

## TLS

Two modes, set by `CertMode`:

- **`Auto`** (default) — Caddy auto-issues and renews the wildcard via ACME DNS-01. Pick a `DnsProvider`:
  - **`Route53`** (default) — needs **no secret**; Caddy's `route53` module authenticates with the instance role (the `.env` sets no AWS keys, so it falls through to instance-metadata credentials).
  - **`Cloudflare`** — set `CloudflareApiToken` (Zone:Read + DNS:Edit).
  - **`GoogleCloudDns`** (experimental) — set `GcpProject` + `GcpCredentialsJson` (base64 SA JSON, `roles/dns.admin`). Less exercised than the other providers; validate the certificate path in a non-production account before relying on it.
  - **`DigitalOcean`** — set `DoAuthToken` (DNS write scope).

  With the non-Route53 providers the stack creates no native Route 53 records, but `DnsAutoRecords=Auto` (the default) still creates the apex + wildcard A records for you via `caddy-dynamicdns` (see [DNS records](#dns-records--automatic-by-default) below); set `DnsAutoRecords=Manual` to point them at the `PublicIp` output yourself (DNS-only / grey-cloud on Cloudflare). Issuance itself doesn't wait on them: DNS-01 is TXT-based, so the cert is typically ready before you cut DNS over.
- **`Byo`** — supply your own wildcard cert + key: set `TlsCertificate` and `TlsCertificateKey` (both base64 PEM, e.g. `base64 -w0 fullchain.pem`). No ACME, no `DnsProvider`; **renewal is your responsibility** (replace the secret + redeploy, or swap the files on the instance and `caddy reload`).

Every credential above is stashed in Secrets Manager and fetched at boot via the instance role — none ride in UserData. Mis-set combinations (Cloudflare/DigitalOcean without a token, GoogleCloudDns without creds, Byo without cert+key, NewServer without subnets) **fail fast** at stack create via template `Rules`, before any resource is built.

### DNS records — automatic by default

- **`Route53`** — with `DnsAutoRecords=Auto` (the default) the stack **creates the apex + wildcard A records natively** (`AWS::Route53::RecordSet` → Elastic IP). Nothing to do.
- **`Cloudflare` / `GoogleCloudDns` / `DigitalOcean`** — with `DnsAutoRecords=Auto` (the default) the appliance **creates and maintains** the apex + wildcard A records for you, pointing them at the Elastic IP via the same `DnsProvider` credential — deploy, then sign in. It manages `<ShareSubdomain>` + `*.<ShareSubdomain>` (or the apex `@` + `*` when `ShareSubdomain` is empty) inside `DnsZone` — the labels come straight from the zone + subdomain you supplied, no derivation (unless the host is on a delegated subdomain — see below). On Cloudflare the records are **DNS-only / grey-cloud**. They live in **your** zone, so they **outlive teardown** — remove them by hand.
- **Delegated subdomain** — if the host lives on a subdomain that is **its own DNS zone** (e.g. `DnsZone=example.com` for the URLs, but `share.example.com` is delegated as a separate zone at your token provider), set **`DnsZoneName`** to that zone. Auto-DNS then writes the A records into it and derives the record labels relative to it — the same zone the ACME/cert path resolves, so a valid cert can't coexist with an A-record write that 404s. A `DnsZoneName` that is neither the host nor a parent of it is **rejected** — auto-DNS is skipped and logged to the instance boot output, and DNS stays Manual, rather than writing a broken record. Leave it **empty** (the default) for the common case where `DnsZone` is itself the zone. Route 53's native records ignore it (they resolve the zone from `HostedZoneId`).
- Set **`DnsAutoRecords=Manual`** when a load balancer, reverse proxy, or corporate NAT/egress sits **in front of** the instance (its IP, not the instance's, is what clients resolve), or you manage DNS yourself — then point the apex + wildcard at the `PublicIp` output. Honored for **every** provider, **including Route53** (the native RecordSets are skipped, so you own the records). Only `CertMode=Byo` forces Manual regardless (no DNS credential).

After deploy, watch issuance over SSM:

```sh
aws ssm start-session --target <instance-id>
sudo docker compose -f /opt/broch/docker-compose.yml logs -f caddy
```

Then sign in at `https://<ShareSubdomain>.<DnsZone>`.

## Recovering an existing installation

Recovering a broken box is a **stack update / redeploy of your existing stack — not a fresh deploy**. The state that matters is the database; the instance is stateless and rebuildable. The one hazard is the **version**: Broch runs EF migrations on boot, so coming back at a *newer* `BrochVersion` than the database silently migrates it **irreversibly** — recovery must return at the version you were running, and upgrades stay a separate, deliberate step.

The recovery path preserves the version for free: a **stack update** (replace the instance, fix parameters) defaults every parameter — `BrochVersion` included — to **Use previous value**. Leave it that way. (`DatabaseMode=Local` is the exception: an update that *replaces* the instance is **not** supported there — the new instance can't attach the data volume the old one still holds. Recover Local via the explicit delete + snapshot-restore + redeploy path under [Database modes](#database-modes) / [Teardown](#teardown), and pin `BrochVersion` to the value you find below.)

**A stack re-create is the risky path**: a fresh template/quick-create launch (e.g. from a re-published marketplace listing) defaults `BrochVersion` to the *latest* release — newer than your database if you have not upgraded since. Before deleting the old stack, note its **Parameters** tab and enter that `BrochVersion` in the new one.

Where to find the version you were running: the (old) stack's **Parameters** tab when the box is dead; Admin → System (or `BROCH_VERSION` in `/opt/broch/.env` over SSM) when it is alive.

## Teardown

```sh
aws cloudformation delete-stack --stack-name broch
```

The RDS instance is created with a `Snapshot` deletion policy — a final snapshot is taken on delete (`ExistingDatabase` deployments leave your DB untouched). In `Local` mode the on-box Postgres data volume likewise has a `Snapshot` deletion policy — a final EBS snapshot is taken on delete; to reuse that data, restore the snapshot into a volume and supply the same `LocalDbAdminPassword` on redeploy. Record the master key before deleting if you intend to redeploy against the same data.

The stack's Secrets Manager entries are **soft-deleted for 30 days** (AWS's minimum recovery window — CloudFormation offers no way to shorten it). This never blocks you: every secret name carries the stack instance's unique id, so a **redeploy under the same stack name gets fresh names** and cannot collide with the lingering ghosts — the same applies to a retry after a first deploy that failed and rolled back. The old entries hold no state Broch needs (the master key is yours, generated passwords die with their database) and expire on their own; force-delete them early with `aws secretsmanager delete-secret --force-delete-without-recovery` only if you want the console tidy.

## Status

The template is lint-validated (`cfn-lint`) and the appliance boot path is exercised end-to-end
(create → boot-to-healthy → teardown). Before relying on it in production, validate the specific
configuration you intend to run in a non-production account — in particular the automatic-certificate
path for your `DnsProvider` (including the default Route 53 instance-role DNS-01) and the
`ExistingDatabase` / `ExistingServer` / `Local` database modes. (The `Local` EBS data-volume
mount + device-resolution path has no automated CI smoke yet — validate it on a real deploy.)
