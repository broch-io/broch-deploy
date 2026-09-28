# AWS VM — CloudFormation template

Broch on a single **EC2 instance**, deployed with CloudFormation. The AWS analog of [`bicep/azure-vm`](../../bicep/azure-vm/) — it runs the canonical [`with-postgres-external` + Caddy compose stack](../../docker-compose/with-postgres-external/) **verbatim** (UserData base64-embeds it at build time, so the box runs the same bytes as a docker-direct deploy).

With Route 53 (the default), Caddy obtains a wildcard HTTPS certificate using the **instance's IAM role**. The stack creates the zone-scoped role, so you enter no DNS token and make no post-deploy role grant. Cloudflare, Google Cloud DNS, and DigitalOcean are also supported with provider credentials, or you can bring your own certificate.

Bring a domain you control and an identity provider app. The AWS console guides you through the database, DNS, and network choices.

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

- An Ubuntu 24.04 EC2 instance (default `t4g.small`, ARM64; the broch image is multi-arch). The AMI comes from Canonical's SSM path for one pinned release, so there's no per-region AMI table and a stack update never swaps the image (and replaces the instance) on its own. The instance patches itself with Ubuntu's unattended upgrades.
- An **Elastic IP** — the stable address the A records point at, kept across instance replacement. First boot waits for CloudFormation to attach it before it talks to any database. To use an address you already allocated (and allow-listed), set `ElasticIpAllocationId` and `ElasticIpAddress`.
- A security group: HTTP (80) + HTTPS/HTTP-3 (443 tcp+udp) from the internet. SSH (22) is **closed by default**; set `SshAllowedCidr` for break-glass, or use **SSM Session Manager** (no SSH).
- An **instance IAM role**: Route 53 (scoped to your zone) for DNS-01, read-only on the secrets this stack generates, and `AmazonSSMManagedInstanceCore` for break-glass.
- A small **Lambda function** and its IAM role (describe-instances plus its own logs) that waits for the instance to be running before CloudFormation attaches the Elastic IP. Its log group (under `/aws/lambda/<stack>-…`) is created by Lambda and outlives the stack — see [Teardown](#teardown).
- `NewServer`: a private, encrypted **RDS Postgres** reachable only from the instance SG; its password is generated into Secrets Manager.
- Your **`BROCH_MASTER_KEY`** (the required `BrochMasterKey` parameter) stashed in Secrets Manager so the instance can read it at boot — customer-supplied, never generated, never seen by Broch.
- With `DnsAutoRecords=Auto` (the default): apex + wildcard **A records** pointing at the Elastic IP, created for you — natively on `Route53` (created with the stack, deleted with it), or via `caddy-dynamicdns` on Cloudflare/GoogleCloudDns/DigitalOcean. With `DnsAutoRecords=Manual` (or `CertMode=Byo`), point the apex + wildcard A records at the `PublicIp` output yourself.

License and telemetry are configured **in-app** (Admin UI) after first sign-in — not at deploy.

## Prerequisites

- AWS credentials that can create EC2 / IAM / RDS / Route 53 / Secrets Manager / EIP / Lambda (a least-privilege deployer also needs `iam:PassRole` for the stack's roles). For the CLI deploy, also an **S3 bucket** in the target region for staging the template (the built template is over CloudFormation's 51,200-byte inline limit); [Launch Stack](#launch-stack-one-click) needs none.
- A **public subnet** for `InstanceSubnetId`: a route to an internet gateway **and** auto-assign public IPv4 enabled (the default VPC's subnets qualify; custom public subnets often have auto-assign off). First boot installs packages and calls the EC2 API from the auto-assigned address before CloudFormation attaches the Elastic IP, and a NAT-routed subnet can't serve the Elastic IP inbound.
- With `DatabaseMode=ExistingDatabase` or `ExistingServer`: the database must accept Postgres from the instance **before** you deploy, or the stack rolls back (broch can't reach healthy without it).
  - **Same (or a peered) VPC:** allow the `InstanceSubnetId` CIDR, or the instance's security group. `ExistingServer` requires this: it opens Postgres on your `DbServerSecurityGroupId` to the instance's security group, which only works within a VPC or across a peering.
  - **Outside the VPC** (`ExistingDatabase`): allocate an Elastic IP first (`aws ec2 allocate-address --domain vpc`), allow-list that address on the database, and pass it as `ElasticIpAllocationId` + `ElasticIpAddress`. First boot waits for CloudFormation to attach it before any database traffic, so the allow-list covers the whole deploy. It fails fast if the address doesn't match the allocation, or if the address is attached to something else. (A stack-allocated EIP can't be allow-listed in advance, since it doesn't exist until the deploy starts.) An instance **replacement** with this external database setup is unsupported; recover by delete and re-create instead (see [Recovering](#recovering-an-existing-installation)).
- A DNS zone for your `DnsZone`. If you choose the default `DnsProvider=Route53`, enter its hosted zone ID, including when you bring your own certificate. For automatic certificates with Cloudflare, Google Cloud DNS, or DigitalOcean, enter that provider's credential in its section. With a bring-your-own certificate, create the Broch hostname and wildcard A records yourself; provider credentials are not needed.
- A **Let's Encrypt contact email** for `AcmeEmail`. **Required** in every `CertMode` (unused when you bring your own certificate, but the stack still needs it) — a blank value fails stack creation instead of booting an instance whose Caddy can't start.
- An **identity provider** app (Auth0, Entra ID, Okta, or any OIDC) — Broch has no local login. Register it as a **confidential (web) client with a client secret**: Broch exchanges the sign-in code server-side, so `AuthClientSecret` is required and a public/SPA app won't work. Register the callback `https://<ShareSubdomain>.<DnsZone>/auth/callback`. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in. Buy at [broch.io/pricing](https://broch.io/pricing).

## Launch Stack (one click)

Choose the identity provider for this deployment. These four preconfigured templates
are generated from this repository's single `template.yaml`; each shows only its
provider's identity fields. They default to a new RDS database (`NewServer`) and
Route 53 DNS. Other database and DNS modes remain available as CloudFormation
parameters in the same templates. To make your own changes, [build and deploy](#build--deploy)
from this repository rather than editing a downloaded template.

CloudFormation shows every parameter section even after you choose a database or DNS
provider. Start with the domain and master key, then choose the DNS and database modes.
Fill in only the sections named for your choices; leave the other provider and database
sections at their defaults. For Route 53, enter your hosted zone ID in the dedicated
Route 53 section. Your identity provider section contains only fields for the launch
link you selected. The template description repeats this guidance in the AWS console.

| Identity provider | Launch Stack (us-east-1) |
| --- | --- |
| Microsoft Entra ID (`AzureAd`) | [Launch](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https%3A%2F%2Fbroch-deploy-templates.s3.us-east-1.amazonaws.com%2Faws-vm%2Fazuread%2Fshared%2Fshared%2Flatest%2Ftemplate.yaml&stackName=broch) |
| Okta | [Launch](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https%3A%2F%2Fbroch-deploy-templates.s3.us-east-1.amazonaws.com%2Faws-vm%2Fokta%2Fshared%2Fshared%2Flatest%2Ftemplate.yaml&stackName=broch) |
| Auth0 | [Launch](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https%3A%2F%2Fbroch-deploy-templates.s3.us-east-1.amazonaws.com%2Faws-vm%2Fauth0%2Fshared%2Fshared%2Flatest%2Ftemplate.yaml&stackName=broch) |
| Generic OIDC | [Launch](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https%3A%2F%2Fbroch-deploy-templates.s3.us-east-1.amazonaws.com%2Faws-vm%2Foidc%2Fshared%2Fshared%2Flatest%2Ftemplate.yaml&stackName=broch) |

Check the identity provider before creating the stack. Switching templates or changing
`AuthProvider` on an existing stack does not rewrite the running instance's first-boot
settings; follow [Recovering an existing installation](#recovering-an-existing-installation)
to rebuild the instance with the new provider.

Each link reads the latest released variant from S3. In AWS, choose your target region before creating the stack. Leave the S3 template URL as it is: the template is read from us-east-1 wherever the stack goes. Fill in the parameters (the same ones as the CLI deploy below; the [prerequisites](#prerequisites) apply, except the S3 staging bucket), tick the IAM acknowledgement (the stack creates IAM roles: the instance role and the gate function's role), and create the stack.

## Build & deploy

To deploy from the CLI, or from your own checkout: the committed `template.yaml` carries `__*_B64__` placeholders (the compose file, both Caddyfiles, the per-provider TLS fragments, and the Amazon RDS CA bundle `db-ca/rds-global-bundle.pem`, whose SHA-256 `build.sh` checks before embedding). `build.sh` embeds the canonical assets and writes `dist/template.yaml` plus the four deployable auth variants listed in `published_variants.yaml`. The example below uses `Auth0`:

```sh
./build.sh

# Generate the master key ONCE, store it in your own secret manager, and reuse the
# SAME value on every redeploy that reuses the database (a fresh key can't decrypt
# existing data). For a first deploy:
export BROCH_MASTER_KEY="$(openssl rand -base64 48)"

# The built template is over CloudFormation's 51,200-byte inline limit, so deploy stages it
# in an S3 bucket you own, in the same region. Create one once:
export STAGING_BUCKET="my-broch-cfn-staging"   # any globally unique name
aws s3 mb "s3://$STAGING_BUCKET"

# DbSubnetIds (NewServer, the default mode) takes a plain comma list of two subnets in
# different AZs -- `deploy --parameter-overrides` does not use create-stack's `\,` escape.
aws cloudformation deploy \
  --template-file dist/template-auth0-shared-shared.yaml \
  --stack-name broch \
  --s3-bucket "$STAGING_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      BrochMasterKey="$BROCH_MASTER_KEY" \
      DnsZone=example.com \
      ShareSubdomain=broch \
      HostedZoneId=Z0123456789ABCDEFGHIJ \
      AcmeEmail=ops@example.com \
      DbSubnetIds=subnet-aaaa,subnet-bbbb \
      VpcId=vpc-0123456789abcdef0 \
      InstanceSubnetId=subnet-aaaa \
      AuthProvider=Auth0 AuthClientId=... AuthClientSecret=... \
      AuthDomain=your-tenant.auth0.com

# URL + where the master key landed:
aws cloudformation describe-stacks --stack-name broch \
  --query "Stacks[0].Outputs" --output table
```

`broch.example.params.json` is a ready-to-edit parameter file: pass it as `--parameter-overrides file://broch.example.params.json` to the `deploy` above, or as `--parameters file://...` to `create-stack`. Use the generated template for its `AuthProvider` value. `create-stack` hits the same size limit, so upload that variant first (`aws s3 cp dist/template-auth0-shared-shared.yaml "s3://$STAGING_BUCKET/template.yaml"`) and pass `--template-url https://<bucket>.s3.<region>.amazonaws.com/template.yaml` rather than `--template-body`, plus `--capabilities CAPABILITY_IAM` (the stack creates IAM roles). (For a console-based deploy of the released template, use [Launch Stack](#launch-stack-one-click); for your own build, create the stack from that same S3 URL.)

> **First boot takes ~3-10 minutes** — instance provisioning, container pulls, DNS propagation, and Let's Encrypt TLS issuance. `https://<ShareSubdomain>.<DnsZone>` will not load until this finishes; that is **expected, not a failed deploy**. `aws cloudformation deploy` blocks until the box reports healthy (the appliance is ready when `https://<host>/healthz` returns `200`), and the stack **rolls back** rather than reporting a false success if boot never goes healthy. The `Readiness` and `DnsHint` stack outputs restate this and the exact A records to create.

> **The master key is yours.** `BrochMasterKey` is **required** and customer-supplied — Broch never generates or sees it. It's stashed in Secrets Manager (`<stack>-<id>/broch-master-key` — the `<id>` is this stack instance's unique CloudFormation id, so a deleted stack's secrets, which linger in Secrets Manager's 30-day deletion window, can never block a redeploy under the same name) in your account only so the instance can read it at boot. Keep the original safe and supply the **same** value on any redeploy that reuses the database (a fresh key can't decrypt existing data).

## Database modes

- **`NewServer`** (default) — provisions the private RDS above. Broch connects as the RDS master to a `brochdb` database.
- **`ExistingDatabase`** — set `DatabaseConnectionString` to a ready Npgsql string; the stack creates no database. Use `SSL Mode=VerifyFull` so the server is authenticated, not just encrypted. For RDS/Aurora, add `Root Certificate=/etc/broch/db-ca/rds-global-bundle.pem` — the Amazon RDS CA bundle this stack ships (see [Database TLS](#database-tls)); for a server with a publicly trusted certificate, `SSL Mode=VerifyFull` alone uses the system trust store.
- **`ExistingServer`** — reuse a Postgres server you already run. Supply `DbServerHost`, `DbServerPort` (default 5432), `DbAdminUsername`, `DbAdminPassword`, and `DbServerSecurityGroupId`. The stack opens Postgres on that SG to this instance and, at boot, uses the admin creds **once** to carve a `brochdb` database + a least-privilege `broch` role (generated password in Secrets Manager, PG15+ `public`-schema owner grant) — idempotent, and it never touches the server's other databases. The admin password is fetched only for the carve and is not written to the instance's `.env`. **Prerequisites:** the instance must be able to reach the server (same VPC or peered/routable), and `DbAdminUsername` must be a role that can `CREATE ROLE`/`CREATE DATABASE` (e.g. the RDS master / `rds_superuser`). `DbSslMode` (default `VerifyFull`) sets the TLS check for both the admin carve and broch's connection — `VerifyFull` needs an RDS/Aurora server and `DbServerHost` set to its endpoint name exactly as AWS shows it; `VerifyFullSystemCa` covers a publicly trusted certificate (including RDS Proxy); see [Database TLS](#database-tls) for when `Require` is the right escape hatch.
- **`Local`** — runs Postgres **on this instance** (the bundled `with-postgres` compose) on a dedicated, encrypted **EBS gp3 data volume** — zero DB prerequisites, deploy → sign in. The volume is mounted at `/var/lib/docker/volumes` before Docker installs, so Postgres's data lives on it. Set **`DataVolumeAz`** to the AZ of `InstanceSubnetId` (**required** — an EBS volume attaches only within its own AZ, and CloudFormation can't derive a subnet's AZ); optionally set `DataVolumeSize` (GiB, default 20) and `LocalDbAdminPassword` (leave empty for a generated password — a supplied one must be letters/digits/`._~-` only, since it is spliced into the DB connection string). **No automated backups / PITR — you own the backups via EBS snapshots** (use `NewServer` for managed backups). The data volume is a separate resource with a `Snapshot` deletion policy, so it survives an instance **stop/start** and a stack **delete** (as a snapshot). To move to a fresh instance, do an explicit **delete + redeploy** — an in-place update that *replaces* the instance is **not** supported (the new instance can't attach the volume the old one still holds). To bring the data to the new stack, set `DataVolumeSnapshotId` to the final snapshot (see [Teardown](#teardown)) and supply the **same** `LocalDbAdminPassword` the data was first initialised with. Postgres keeps the password from first data-dir init, so a redeploy that *generates* a fresh one cannot open the old data — if you never set `LocalDbAdminPassword` (generated password), **read the current value before deleting**: `POSTGRES_PASSWORD` in `/opt/broch/.env` on the instance (via SSM) is always authoritative — it is the password the data directory was initialised with. In Secrets Manager, use the entry that **initialised your data directory** (search by the `broch-local-db-password` suffix): for a stack first deployed on this template version that is the current `<stack>-<id>/broch-local-db-password` entry, but for a deployment **upgraded from an older template version** it is the **retained pre-upgrade entry** (`<stack>/broch-local-db-password`, kept alive through the upgrade precisely for this) — the post-upgrade entry holds a freshly generated value your database has never used. Pass the recovered value explicitly on the redeploy.

### Database TLS

By default, database connections the stack builds are **encrypted and authenticated**: Npgsql's `SSL Mode=VerifyFull` checks that the server's certificate chains to a trusted CA **and** names the host broch connects to. (`SSL Mode=Require` would only encrypt — anyone on the network path could impersonate the server and collect the database credentials.) The exceptions are the ones you choose: `ExistingServer` with `DbSslMode=Require`, and an `ExistingDatabase` string that does not use `VerifyFull`. `Local` runs Postgres on the instance itself, over the private Docker network.

- The stack ships the **Amazon RDS CA bundle** (every RDS/Aurora root CA, commercial AWS regions), pinned by SHA-256 in `build.sh`. It lands at `/opt/broch/db-ca/rds-global-bundle.pem` on the instance and is mounted read-only into broch at `/etc/broch/db-ca/rds-global-bundle.pem`.
- **`NewServer`** — always `VerifyFull` against that bundle; the host is the RDS endpoint, so the name matches.
- **`ExistingServer`** — `DbSslMode` applies to both the one-time admin carve (`psql`) and broch's own connection:
  - `VerifyFull` (default) — verify against the RDS bundle. For RDS and Aurora endpoints, with `DbServerHost` exactly as AWS shows it.
  - `VerifyFullSystemCa` — the same full check against the OS trust store. For a server whose certificate comes from a public CA, **including RDS Proxy** (its certificates come from ACM and chain to Amazon Root CA, which the RDS bundle does not contain). It changes **which CA** is trusted, not the hostname check, so it does **not** help when `DbServerHost` is an IP or an alias.
  - `Require` — encrypts but does **not** authenticate the server. An explicit, unauthenticated fallback for a confirmed limitation you accept: a host name no certificate covers, or a private CA. The carve never falls back to plaintext in any mode.

  An **IP or your own CNAME/alias** as `DbServerHost` fails verification in both verify modes, because the certificate names the endpoint, not your alias. Fix it by using a host name the certificate covers (the endpoint name exactly as AWS shows it), or a server certificate that covers your host name. Only if neither is possible, choose `Require` knowingly.

  If the carve cannot connect, boot stops at once with a `FATAL` line naming `DbSslMode` and the likely cause, and the stack rolls back without waiting out the health timeout. The rollback **terminates the instance**, and a terminated instance's console output stays readable only briefly, so to keep the evidence deploy with `--disable-rollback` (`aws cloudformation deploy`) or `--on-failure DO_NOTHING` (`create-stack`). Then read the line with `aws ec2 get-console-output --instance-id <id> --latest`, and delete the failed stack yourself afterwards.
- **`ExistingDatabase`** — your connection string decides; see the mode description above.
- **AWS GovCloud (US) and China** use RDS CAs that the bundle does not contain. There, `NewServer` and `ExistingServer` + `VerifyFull` stop at boot with a `FATAL` explaining this (the stack rolls back); use `ExistingServer` with `VerifyFullSystemCa` for a publicly trusted server, or `Require` (encrypt only).

### Updating the stack

On first boot, the instance waits until CloudFormation attaches the Elastic IP before it
configures the database. If the address is attached elsewhere or never arrives, boot fails and
the stack rolls back instead of connecting from an unapproved source address.

- **`BrochVersion` applies in place** — see [Upgrading Broch](#upgrading-broch).
- **Everything else the instance reads is set at its first boot.** `.env` values (the IdP settings, `BrochImage`, the Elastic IP, DNS and TLS settings, `DbServer*`), the compose file, Caddyfile and TLS fragments are written once, when the instance first boots. A stack update that changes them doesn't reach the running instance: a UserData change stops and starts it but doesn't rewrite anything. A newer template release is the same. To apply such changes, rebuild the instance (see [Recovering](#recovering-an-existing-installation)).
- **The instance is kept.** `UbuntuAmi` is pinned to one Canonical release, so an update replaces the instance only when you change `UbuntuAmi` or `InstanceSubnetId`, or a template release changes the instance's root disk. Keep `UbuntuAmi`'s previous value when you update to a newer template: `aws cloudformation deploy` reuses previous values by default, and the console's "Use existing value" does the same.
- **`ElasticIpAllocationId` / `ElasticIpAddress` and `DataVolumeSnapshotId` are create-only.** Changing the EIP leaves the old address in `.env` (and in caddy-dynamicdns's records). Changing the snapshot detaches the live data volume.

### Upgrading Broch

Upgrade by **updating the stack's `BrochVersion` parameter** to the new release (a published version number newer than the one you're running), keeping every other parameter's previous value and the template you deployed.

1. **Back up first.** Broch migrates the database forward on start, and there is no going back. `Local`: snapshot the data volume (`aws ec2 create-snapshot --volume-id <the <stack>-data volume>`). `NewServer`: take an RDS snapshot.
2. **Update the parameter.** In the console: **Update** → *Use existing template* → change only `BrochVersion`. From the CLI, deploy the **same** built template you deployed before (a newer build is also a template update):

   ```sh
   # <provider> = the variant you deployed (auth0, azuread, okta, or oidc); <new-version> = e.g. X.Y.Z
   aws cloudformation deploy --template-file dist/template-<provider>-shared-shared.yaml --stack-name broch \
     --s3-bucket "$STAGING_BUCKET" --capabilities CAPABILITY_IAM \
     --parameter-overrides BrochVersion=<new-version>
   ```

3. **Wait a few minutes, then check** `https://<host>/healthz` and Admin → System.

The update changes only the instance's metadata: no stop/start, no replacement. Within a minute `cfn-hup` on the instance picks it up. It waits until the whole stack update has completed. It then pulls the new image **before** touching the running container, and recreates only broch (Caddy keeps serving).

- **A tag it can't pull** (a typo, a registry problem) leaves the old version running, and it retries every minute. Fix `BrochVersion` with another update.
- **A downgrade between release numbers** (say `1.32.0` → `1.31.0`) is refused: the box stays on the newer version and writes the reason to `/opt/broch/version-mismatch`. Set `BrochVersion` back to the running version. (`latest` has no release number, so a move off `latest` can't be checked.)
- **If the new version hasn't appeared after five minutes**, read `sudo journalctl -t broch-version` over SSM.

Don't upgrade by editing `.env` by hand. `broch.service` resets `BROCH_VERSION` to the stack's value every time it starts. If the hand-edited version is **newer** than the stack's, broch refuses to start rather than run an older release on a database already migrated for the newer one. Update the stack's `BrochVersion` to match.

Stacks created from an earlier template version don't run `cfn-hup`. Rebuild their instance once (see [Recovering](#recovering-an-existing-installation); for `Local` that means delete and re-create).

## TLS

Two modes, set by `CertMode`:

- **`Auto`** (default) — Caddy auto-issues and renews the wildcard via ACME DNS-01. Pick a `DnsProvider`:
  - **`Route53`** (default) — needs **no secret**; Caddy's `route53` module authenticates with the instance role (the `.env` sets no AWS keys, so it falls through to instance-metadata credentials).
  - **`Cloudflare`** — set `CloudflareApiToken` (Zone:Read + DNS:Edit).
  - **`GoogleCloudDns`** (experimental) — set `GcpProject` + `GcpCredentialsJson` (base64 SA JSON, `roles/dns.admin`). Less exercised than the other providers; validate the certificate path in a non-production account before relying on it.
  - **`DigitalOcean`** — set `DoAuthToken` (DNS write scope).

  With the non-Route53 providers the stack creates no native Route 53 records, but `DnsAutoRecords=Auto` (the default) still creates the apex + wildcard A records for you via `caddy-dynamicdns` (see [DNS records](#dns-records--automatic-by-default) below); set `DnsAutoRecords=Manual` to point them at the `PublicIp` output yourself (DNS-only / grey-cloud on Cloudflare). Issuance itself doesn't wait on them: DNS-01 is TXT-based, so the cert is typically ready before you cut DNS over.
- **`Byo`** — supply your own wildcard cert + key: set `TlsCertificate` and `TlsCertificateKey` (both base64 PEM, e.g. `base64 -w0 fullchain.pem`). No ACME, no `DnsProvider`; **renewal is your responsibility** (replace the secret + redeploy, or swap the files on the instance and `caddy reload`).

Every credential above is stashed in Secrets Manager and fetched at boot via the instance role — none ride in UserData. Mis-set combinations (a missing `AuthClientId`/`AuthClientSecret` or provider-specific identity field, Cloudflare/DigitalOcean without a token, GoogleCloudDns without creds, Byo without cert+key, NewServer without subnets) **fail fast** at stack create via template `Rules`, before any resource is built.

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

Recovering a broken box means **rebuilding the instance of your existing stack — not a fresh deploy**. The state that matters is the database; the instance is stateless and rebuildable. The one hazard is the **version**: Broch runs EF migrations on boot, so coming back at a *newer* `BrochVersion` than the database silently migrates it **irreversibly** — recovery must return at the version you were running, and upgrades stay a separate, deliberate step.

**First, check the version.** If the box is alive, compare Admin → System (or `/opt/broch/stack-version` over SSM, and `/opt/broch/version-mismatch` if it exists) with the stack's `BrochVersion`. They differ only after a refused downgrade. Use the **higher** one: the database has been migrated for it.

**Rebuild the instance with a stack update that replaces it**: set `UbuntuAmi` to a newer Canonical release path (for example this template's default), keep `BrochVersion` at the version you just checked, and leave every other parameter at **Use previous value**. The new instance runs first boot from scratch, at the version the stack records. (An update that doesn't change `UbuntuAmi` keeps the broken instance; see [Updating the stack](#updating-the-stack).) Two exceptions:

- **`DatabaseMode=Local`**: an update that replaces the instance is **not** supported, since the new instance can't attach the data volume the old one still holds. Delete the stack and create a new one with `DataVolumeSnapshotId` set to the final snapshot (see [Teardown](#teardown)), pinning `BrochVersion` to the value you find below.
- **A bring-your-own Elastic IP with a database outside the VPC**: instance replacement is unsupported because the old instance may still hold the address while the new instance waits for it before database setup. Delete the stack and create it again with the same `ElasticIpAllocationId`: CloudFormation attaches the address and the new instance waits for it before database setup.

**A stack re-create is the risky path**: a fresh launch from a newer copy of the template defaults `BrochVersion` to the *latest* release — newer than your database if you have not upgraded since. Before deleting the old stack, note its **Parameters** tab and enter that `BrochVersion` in the new one.

Where to find the version you were running: the (old) stack's **Parameters** tab when the box is dead (after a refused downgrade it can be lower than what ran; if you know that happened, use the higher version). When the box is alive, Admin → System is authoritative.

## Teardown

```sh
aws cloudformation delete-stack --stack-name broch
```

The RDS instance is created with a `Snapshot` deletion policy — a final snapshot is taken on delete (`ExistingDatabase` deployments leave your DB untouched). In `Local` mode the on-box Postgres data volume likewise has a `Snapshot` deletion policy — a final EBS snapshot is taken on delete; to reuse that data, create the new stack with `DataVolumeSnapshotId` set to that snapshot (find it by its `<stack>-data` Name tag), `DataVolumeAz` set to the new subnet's AZ, `DataVolumeSize` at least the snapshot's size, and the same `LocalDbAdminPassword`, `BrochMasterKey` and `BrochVersion`. Record the master key before deleting if you intend to redeploy against the same data.

The stack's Secrets Manager entries are **soft-deleted for 30 days** (AWS's minimum recovery window — CloudFormation offers no way to shorten it). This never blocks you: every secret name carries the stack instance's unique id, so a **redeploy under the same stack name gets fresh names** and cannot collide with the lingering ghosts — the same applies to a retry after a first deploy that failed and rolled back. The old entries hold no state Broch needs (the master key is yours, generated passwords die with their database) and expire on their own; force-delete them early with `aws secretsmanager delete-secret --force-delete-without-recovery` only if you want the console tidy.

The Elastic IP gate function's CloudWatch log group (under `/aws/lambda/<stack>-…`) is created by Lambda, not the stack, so `delete-stack` leaves it behind. To remove it, find its name and delete it:

```sh
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/broch- --query 'logGroups[].logGroupName'
aws logs delete-log-group --log-group-name <name from the list above>
```

## Status

The template is lint-validated (`cfn-lint`) and the appliance boot path is exercised end-to-end
(create → boot-to-healthy → teardown). Before relying on it in production, validate the specific
configuration you intend to run in a non-production account — in particular the automatic-certificate
path for your `DnsProvider` (including the default Route 53 instance-role DNS-01) and the
`ExistingDatabase` / `ExistingServer` database modes. `NewServer` and `Local` (including the EBS
data-volume mount and device resolution) are live-deployed in CI on the stock Ubuntu AMI. Both lanes
also check that the Elastic IP is on the instance before its database traffic, and upgrade in place by a `BrochVersion` stack
update (metadata-only, same instance, healthy on the new version). Restoring `Local` from
`DataVolumeSnapshotId`, bringing your own Elastic IP, and the downgrade and bad-tag guards are not
exercised in CI.
