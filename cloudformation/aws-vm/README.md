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
- An **instance IAM role**: Route 53 (scoped to your zone) for DNS-01, read-only on the secrets this stack creates (and, with a bring-your-own certificate in your own secrets, on exactly those secrets), and `AmazonSSMManagedInstanceCore` for break-glass.
- A small **Lambda function** and its IAM role (describe-instances plus its own logs) that waits for the instance to be running before CloudFormation attaches the Elastic IP. Its log group (under `/aws/lambda/<stack>-…`) is created by Lambda and outlives the stack — see [Teardown](#teardown).
- `NewServer`: a private, encrypted **RDS Postgres** reachable only from the instance SG; its password is generated into Secrets Manager.
- Your **`BROCH_MASTER_KEY`**, Broch's at-rest encryption root, in Secrets Manager so the instance can read it at boot. The stack generates it unless you supply `BrochMasterKey`. It is born in your account and Broch never sees it, so **save a copy** after the deploy (see [The master key](#the-master-key)).
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
- An **identity provider** app (Auth0, Entra ID, Okta, or any OIDC) — Broch has no local login. Register it as a **confidential (web) client with a client secret**: Broch exchanges the sign-in code server-side, so `AuthClientSecret` is required and a public/SPA app won't work. Register the callback `https://<ShareSubdomain>.<DnsZone>/auth/callback`. Auth0 also needs an **API** (its Identifier is `AuthAudience`), with the Broch application authorized for **User Access** on the API's **Application Access** tab — an API that requires that grant rejects every sign-in without it. See the [identity-provider guides](https://broch.io/docs/identity-providers/).
- A Broch license — activated in-app after first sign-in. Buy at [broch.io/pricing](https://broch.io/pricing).

## Launch Stack (one click)

Choose the identity provider for this deployment. These four preconfigured templates
are generated from this repository's single `template.yaml`; each shows only its
provider's identity fields. They default to a new RDS database (`NewServer`) and
Route 53 DNS. Other database and DNS modes remain available as CloudFormation
parameters in the same templates. To make your own changes, [build and deploy](#build--deploy)
from this repository rather than editing a downloaded template.

CloudFormation shows every parameter section even after you choose a database or DNS
provider. Start with the domain (leave the master key blank for a new installation: the
stack generates it), then choose the DNS and database modes.
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

Each link reads the latest released variant from S3. In AWS, choose your target region before creating the stack. Leave the S3 template URL as it is: the template is read from us-east-1 wherever the stack goes. Fill in the parameters (the same ones as the CLI deploy below; the [prerequisites](#prerequisites) apply, except the S3 staging bucket), tick the IAM acknowledgement (the stack creates IAM roles: the instance role and the gate function's role), and create the stack. When it completes, save the master key: the stack's **Outputs** tab shows the command that prints it (`MasterKeyBackupCommand`), or open the `MasterKeySecretArn` secret in the Secrets Manager console and choose **Retrieve secret value**.

For Microsoft Entra ID (`AzureAd`), leave `AuthAuthority` blank and supply `AuthInstance` and `AuthTenantId`. Broch 1.36 derives the v2.0 authority. The general template rejects an AzureAd authority override; use the tenant/instance fields instead. Entra v1 cannot supply the signed refresh identity Broch requires.

## Build & deploy

To deploy from the CLI, or from your own checkout: the committed `template.yaml` carries `__*_B64__` placeholders (the compose file, both Caddyfiles, the per-provider TLS fragments, and the Amazon RDS CA bundle `db-ca/rds-global-bundle.pem`, whose SHA-256 `build.sh` checks before embedding). `build.sh` embeds the canonical assets and writes `dist/template.yaml` plus the four deployable auth variants listed in `published_variants.yaml`. The example below uses `Auth0`:

```sh
./build.sh

# The built template is over CloudFormation's 51,200-byte inline limit, so deploy stages it
# in an S3 bucket you own, in the same region. Create one once:
export STAGING_BUCKET="my-broch-cfn-staging"   # any globally unique name
aws s3 mb "s3://$STAGING_BUCKET"

# DbSubnetIds (NewServer, the default mode) takes a plain comma list of two subnets in
# different AZs -- `deploy --parameter-overrides` does not use create-stack's `\,` escape.
# BrochMasterKey is left out: the stack generates the master key into Secrets Manager.
aws cloudformation deploy \
  --template-file dist/template-auth0-shared-shared.yaml \
  --stack-name broch \
  --s3-bucket "$STAGING_BUCKET" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      DnsZone=example.com \
      ShareSubdomain=broch \
      HostedZoneId=Z0123456789ABCDEFGHIJ \
      AcmeEmail=ops@example.com \
      DbSubnetIds=subnet-aaaa,subnet-bbbb \
      VpcId=vpc-0123456789abcdef0 \
      InstanceSubnetId=subnet-aaaa \
      AuthProvider=Auth0 AuthClientId=... AuthClientSecret=... \
      AuthDomain=your-tenant.auth0.com AuthAudience='<your-auth0-api-identifier>'

# URL, the master key's secret, and the command that prints the key:
aws cloudformation describe-stacks --stack-name broch \
  --query "Stacks[0].Outputs" --output table

# Save the master key once, in your own password manager or secret store (see "The master key"):
aws secretsmanager get-secret-value --secret-id "$(aws cloudformation describe-stacks --stack-name broch \
  --query "Stacks[0].Outputs[?OutputKey=='MasterKeySecretArn'].OutputValue" --output text)" \
  --query SecretString --output text
```

`broch.example.params.json` is a ready-to-edit parameter file (it leaves out `BrochMasterKey`, so a new stack generates the key and a `deploy` update keeps it; add it only for a new stack that reuses a database, and see [The master key](#the-master-key) before using it with `update-stack`): pass it as `--parameter-overrides file://broch.example.params.json` to the `deploy` above, or as `--parameters file://...` to `create-stack`. Use the generated template for its `AuthProvider` value. `create-stack` hits the same size limit, so upload that variant first (`aws s3 cp dist/template-auth0-shared-shared.yaml "s3://$STAGING_BUCKET/template.yaml"`) and pass `--template-url https://<bucket>.s3.<region>.amazonaws.com/template.yaml` rather than `--template-body`, plus `--capabilities CAPABILITY_IAM` (the stack creates IAM roles). (For a console-based deploy of the released template, use [Launch Stack](#launch-stack-one-click); for your own build, create the stack from that same S3 URL.)

> **First boot takes ~3-10 minutes** — instance provisioning, container pulls, DNS propagation, and Let's Encrypt TLS issuance. `https://<ShareSubdomain>.<DnsZone>` will not load until this finishes; that is **expected, not a failed deploy**. `aws cloudformation deploy` blocks until the box reports healthy (the appliance is ready when `https://<host>/healthz` returns `200`), and the stack **rolls back** rather than reporting a false success if boot never goes healthy. The `Readiness` and `DnsHint` stack outputs restate this and the exact A records to create.

### The master key

`BROCH_MASTER_KEY` is Broch's at-rest encryption root: it protects the sign-in tokens, the activated license and the secrets Broch keeps in its database. Leave `BrochMasterKey` blank and the stack generates it (64 letters and digits) into Secrets Manager as `<stack>-<id>/broch-master-key`, where the instance reads it at boot. The `<id>` is this stack instance's unique CloudFormation id, so a deleted stack's secrets can never block a redeploy under the same name. The key is born in your account; Broch never sees it and cannot recover it.

**Save a copy after the first deploy**, outside this stack: in a password manager or your own secret store. Run the command in the `MasterKeyBackupCommand` output (or the one above), or open the `MasterKeySecretArn` secret in the Secrets Manager console and choose **Retrieve secret value**.

> **Read first: a blank key is only right for a brand-new database.** On a new stack, a blank `BrochMasterKey` generates a new key, and the template cannot tell whether the database it connects to already holds data (a `Local` snapshot restore is the exception: stack creation fails without the key). Two ways to replace the key by accident:
>
> 1. **New stack on an existing database** (`ExistingDatabase`, `ExistingServer`, a `Local` snapshot restore, or a stack you deleted and recreated): enter the saved key as `BrochMasterKey`. With a blank, the new instance boots with a different key and cannot decrypt the old data from its first start: users sign in again and the license re-activates.
> 2. **Updating a stack whose key you supplied:** keep the existing value. In the console choose **Use existing value**; with `update-stack`, change sets or infrastructure-as-code tools pass `ParameterKey=BrochMasterKey,UsePreviousValue=true`, and do not reuse `broch.example.params.json` unchanged, because it leaves the key out. (A stack whose key the template generated keeps it through an update, but follow the same habit.) On an update nothing breaks at the time: the running instance keeps the key it booted with, and the mistake shows up at the next instance rebuild.
>
> A replaced key is recoverable for a while, not lost: a deleted stack's secret is retained, and a replaced value stays readable as `AWSPREVIOUS` until the secret is next written (below).

- **Stack updates and instance rebuilds keep the key.** The secret outlives both, and a rebuilt instance reads it again, so a database that survives the rebuild (RDS, `ExistingDatabase`, `ExistingServer`) keeps working. On an update, keep `BrochMasterKey` at its existing value: the console's **Use existing value**; `aws cloudformation deploy` keeps it when you leave it out of `--parameter-overrides`. **`update-stack`, change sets and infrastructure-as-code tools are different:** pass `ParameterKey=BrochMasterKey,UsePreviousValue=true` explicitly. Leaving it out there sends the empty default, so a stack whose key you supplied gets a newly generated key instead.
- **A changed key is recoverable only briefly.** Entering a different value, or clearing one you supplied, changes the stored key. The key it replaced stays readable as the secret's previous version only until the secret is next written, so save it now: `aws secretsmanager get-secret-value --secret-id <MasterKeySecretArn> --version-stage AWSPREVIOUS --query SecretString --output text`. The running instance keeps the key it booted with; the next rebuilt instance gets the new one.
- **A new stack gets a new key.** Deleting the stack keeps the secret (see [Teardown](#teardown)), so the key of a deleted stack stays readable until you delete it. A new stack that reuses the old database (`ExistingDatabase`, `ExistingServer`, or `Local` with `DataVolumeSnapshotId`) needs the saved key as `BrochMasterKey`; for a `Local` snapshot restore, stack creation fails at once without it. With a different key, Broch cannot decrypt what the old key protected (recoverable: users sign in again and the license re-activates, but disruptive).
- **To supply your own key** instead (for example to store it in your own secret store before the deploy), generate one with `openssl rand -base64 48` and pass it as `BrochMasterKey`. It needs at least 32 characters, with no single quote or line break, and must not end with a backslash. Stacks deployed before the stack could generate the key keep the key they were given.

## Database modes

- **`NewServer`** (default) — provisions the private RDS above. Broch connects as the RDS master to a `brochdb` database.

  **If stack creation fails on `BrochDB` with "no Availability Zones with sufficient capacity"**, RDS has run out of that instance size in the Availability Zones your `DbSubnetIds` cover. It fails before the instance is created, and the stack rolls back on its own, so nothing is left running (unless you chose to preserve successfully provisioned resources, or deployed with `--disable-rollback`: then delete the stack to remove what it created). Delete the failed stack (it stays in `ROLLBACK_COMPLETE` and blocks its name), then deploy again with another `DbInstanceClass` (for example `db.t4g.small` or `db.t3.micro`), or with `DbSubnetIds` covering more Availability Zones. Waiting and retrying also works; AWS reports the shortage as temporary.
- **`ExistingDatabase`** — set `DatabaseConnectionString` to a ready Npgsql string; the stack creates no database. Use `SSL Mode=VerifyFull` so the server is authenticated, not just encrypted. For RDS/Aurora, add `Root Certificate=/etc/broch/db-ca/rds-global-bundle.pem` — the Amazon RDS CA bundle this stack ships (see [Database TLS](#database-tls)); for a server with a publicly trusted certificate, `SSL Mode=VerifyFull` alone uses the system trust store.
- **`ExistingServer`** — reuse a Postgres server you already run. Supply `DbServerHost`, `DbServerPort` (default 5432), `DbAdminUsername`, `DbAdminPassword`, and `DbServerSecurityGroupId`. The stack opens Postgres on that SG to this instance and, at boot, uses the admin creds **once** to carve a `brochdb` database + a least-privilege `broch` role (generated password in Secrets Manager, PG15+ `public`-schema owner grant) — idempotent, and it never touches the server's other databases. The admin password is fetched only for the carve and is not written to the instance's `.env`. **Prerequisites:** the instance must be able to reach the server (same VPC or peered/routable), and `DbAdminUsername` must be a role that can `CREATE ROLE`/`CREATE DATABASE` (e.g. the RDS master / `rds_superuser`). `DbSslMode` (default `VerifyFull`) sets the TLS check for both the admin carve and broch's connection — `VerifyFull` needs an RDS/Aurora server and `DbServerHost` set to its endpoint name exactly as AWS shows it; `VerifyFullSystemCa` covers a publicly trusted certificate (including RDS Proxy); see [Database TLS](#database-tls) for when `Require` is the right escape hatch.
- **`Local`** — runs Postgres **on this instance** (the bundled `with-postgres` compose) on a dedicated, encrypted **EBS gp3 data volume** — zero DB prerequisites, deploy → sign in. The volume is mounted at `/var/lib/docker/volumes` before Docker installs, so Postgres's data lives on it. Set **`DataVolumeAz`** to the AZ of `InstanceSubnetId` (**required** — an EBS volume attaches only within its own AZ, and CloudFormation can't derive a subnet's AZ); optionally set `DataVolumeSize` (GiB, default 20) and `LocalDbAdminPassword` (leave empty for a generated password — a supplied one must be letters/digits/`._~-` only, since it is spliced into the DB connection string). **No automated backups / PITR — you own the backups via EBS snapshots** (use `NewServer` for managed backups). The data volume is a separate resource with a `Snapshot` deletion policy, so it survives an instance **stop/start** and a stack **delete** (as a snapshot). To move to a fresh instance, do an explicit **delete + redeploy** — an in-place update that *replaces* the instance is **not** supported (the new instance can't attach the volume the old one still holds). To bring the data to the new stack, set `DataVolumeSnapshotId` to the final snapshot (see [Teardown](#teardown)), supply the **same** `LocalDbAdminPassword` the data was first initialised with, and the old stack's master key as `BrochMasterKey` (see [The master key](#the-master-key)). Postgres keeps the password from first data-dir init, so a redeploy that *generates* a fresh one cannot open the old data — if you never set `LocalDbAdminPassword` (generated password), **save the current value before deleting** (its secret also stays after the delete, see [Teardown](#teardown), but the instance holding the authoritative copy does not): `POSTGRES_PASSWORD` in `/opt/broch/.env` on the instance (via SSM) is always authoritative — it is the password the data directory was initialised with. In Secrets Manager, use the entry that **initialised your data directory** (search by the `broch-local-db-password` suffix): for a stack first deployed on this template version that is the current `<stack>-<id>/broch-local-db-password` entry, but for a deployment **upgraded from an older template version** it is the **retained pre-upgrade entry** (`<stack>/broch-local-db-password`, kept alive through the upgrade precisely for this) — the post-upgrade entry holds a freshly generated value your database has never used. Pass the recovered value explicitly on the redeploy.

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
- **A bring-your-own certificate renews in place** — see [TLS](#tls). The instance checks its certificate secrets every hour.
- **Everything else the instance reads is set at its first boot.** `.env` values (the IdP settings, `BrochImage`, the Elastic IP, DNS and TLS settings, `DbServer*`), the compose file, Caddyfile and TLS fragments are written once, when the instance first boots. A stack update that changes them doesn't reach the running instance: a UserData change stops and starts it but doesn't rewrite anything. A newer template release is the same, and so is switching a bring-your-own certificate between the inline parameters and the secret ARNs. To apply such changes, rebuild the instance (see [Recovering](#recovering-an-existing-installation)).
- **Keep `BrochMasterKey` at its existing value** — see [The master key](#the-master-key).
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
- **`Byo`** — supply your own wildcard certificate and private key. No ACME and no DNS credential (with the default `DnsProvider=Route53`, `HostedZoneId` is still required); **renewal is your responsibility**. The certificate must cover both your Broch hostname and its wildcard. Supply each of the two, the full chain and the key, one of two ways:

  - **In a Secrets Manager secret you create** (any certificate fits: a secret holds up to 64 KB): set `TlsCertificateSecretArn` and `TlsCertificateKeySecretArn` to the secrets' full ARNs. Store the PEM text as it is (base64 PEM also works). Create the secrets in the stack's account, in any region, with the default encryption key, then use the `ARN` each command prints (the full ARN ends in a 6-character suffix after the name, which the stack needs):

    ```sh
    aws secretsmanager create-secret --name broch/tls-fullchain --secret-string file://fullchain.pem --query ARN --output text
    aws secretsmanager create-secret --name broch/tls-privkey --secret-string file://privkey.pem --query ARN --output text
    ```

    The instance role may read exactly these two secrets. With the default `aws/secretsmanager` encryption key, nothing more is needed. If the secrets are encrypted with a **customer-managed KMS key** (`--kms-key-id` on `create-secret`), also set `TlsSecretsKmsKeyArn` to that key's full ARN (not an alias): the stack then lets the instance role decrypt with exactly that key, and only through Secrets Manager. That is all you need when the key policy lets IAM policies grant access (its `arn:aws:iam::<account>:root` statement allowing `kms:*`, as in the default key policy).

    If the key policy doesn't, add this statement to it **before the first deploy**. The role doesn't exist yet and its name is generated, so the statement names the account and narrows it to principals tagged `broch-stack=<stack>` (the stack tags its instance role so, whatever the stack name's length) and to calls through Secrets Manager. Keep `TlsSecretsKmsKeyArn` set too: with the account as principal, the role also needs the IAM permission the stack gives it. Replace `<account>`, `<stack>` (the stack name exactly) and `<key-region>`:

    ```json
    {
      "Sid": "BrochInstanceRoleDecryptViaSecretsManager",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<account>:root" },
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/broch-stack": "<stack>",
          "kms:ViaService": "secretsmanager.<key-region>.amazonaws.com"
        }
      }
    }
    ```

    In AWS GovCloud (US) the account principal is `arn:aws-us-gov:iam::<account>:root`; in the China regions it is `arn:aws-cn:iam::<account>:root` and the service name is `secretsmanager.<key-region>.amazonaws.com.cn`. Anyone who can tag an IAM role and grant it `kms:Decrypt` in this account could also match the statement; both are administrator permissions. The stack's `InstanceRoleArn` output gives the exact role, for adjusting the key policy of a stack that is already running (for example when you switch its secrets to a customer-managed key).
  - **Inline as stack parameters**: set `TlsCertificate` and `TlsCertificateKey` to the base64 PEM (`base64 -w0 fullchain.pem`). CloudFormation limits a parameter value to 4,096 bytes, so this works only for a pair that fits: an ECDSA certificate's chain and key usually do, while an RSA chain (Let's Encrypt's included) usually doesn't, and neither does an RSA 4096-bit key. Check each with `base64 -w0 fullchain.pem | wc -c` and `base64 -w0 privkey.pem | wc -c`; if either is over 4096, use the secret instead. An oversized value fails the deploy before anything is created, with an error like `Template format error: Parameter 'TlsCertificate' default value '****' length is greater than 4096.` (naming `TlsCertificateKey` for the key; CloudFormation says "default value" even for a value you supplied). The stack stores the pair in its own secrets.

  You can mix the two (say an inline key with a chain in a secret), but not set both forms for the same half. At first boot the instance installs the pair into `/opt/broch/certs/` and refuses a key that doesn't match the chain's first certificate, which fails the deploy at once.

  **To renew**, replace the value; the stack doesn't change and nothing is rebuilt. Within about an hour the instance installs the new pair and reloads Caddy (`broch-tls-refresh.timer`), only once the chain and key match, so you can update them one after the other.

  - Secrets you created: put the new value into the **same** secrets (a new secret has a new ARN, which the running instance doesn't know):

    ```sh
    aws secretsmanager put-secret-value --secret-id <TlsCertificateSecretArn> --secret-string file://fullchain.pem
    aws secretsmanager put-secret-value --secret-id <TlsCertificateKeySecretArn> --secret-string file://privkey.pem
    ```

  - Inline parameters: update the stack's `TlsCertificate` and `TlsCertificateKey`, keeping every other parameter's previous value and the template you deployed.

  To install it at once instead of waiting, run `sudo systemctl start broch-tls-refresh.service` over SSM; `sudo journalctl -t broch-tls` shows what it did, including when a chain and key don't match.

  Instances created by an earlier template version have no `broch-tls-refresh.timer` and read the pair at first boot only. Renew them by updating `TlsCertificate` and `TlsCertificateKey`, then, over SSM, fetching the pair again and reloading Caddy (without `--force`, Caddy sees an unchanged config and keeps the old certificate). `<stack>-<id>` is the secret-name prefix, as in the `MasterKeySecretArn` output:

  ```sh
  aws --region <region> secretsmanager get-secret-value --secret-id '<stack>-<id>/broch-tls-cert' --query SecretString --output text | base64 -d | sudo tee /opt/broch/certs/fullchain.pem > /dev/null
  aws --region <region> secretsmanager get-secret-value --secret-id '<stack>-<id>/broch-tls-key' --query SecretString --output text | base64 -d | sudo tee /opt/broch/certs/privkey.pem > /dev/null
  sudo docker compose -f /opt/broch/docker-compose.yml exec caddy caddy reload --config /etc/caddy/Caddyfile --force
  ```

  Rebuilding such an instance (see [Recovering](#recovering-an-existing-installation)) gives it the timer.

Every credential above is stashed in Secrets Manager (or read from your own secret) and fetched at first boot via the instance role — none ride in UserData. Mis-set combinations (a missing `AuthClientId`/`AuthClientSecret` or provider-specific identity field, Cloudflare/DigitalOcean without a token, GoogleCloudDns without creds, Byo without a chain and key or with both forms of one, NewServer without subnets, a `Local` snapshot restore without `BrochMasterKey`) **fail fast** at stack create via template `Rules`, before any resource is built.

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

- **`DatabaseMode=Local`**: an update that replaces the instance is **not** supported, since the new instance can't attach the data volume the old one still holds. Delete the stack and create a new one with `DataVolumeSnapshotId` set to the final snapshot (see [Teardown](#teardown)), pinning `BrochVersion` to the value you find below and entering the saved master key as `BrochMasterKey`.
- **A bring-your-own Elastic IP with a database outside the VPC**: instance replacement is unsupported because the old instance may still hold the address while the new instance waits for it before database setup. Delete the stack and create it again with the same `ElasticIpAllocationId` and the saved master key as `BrochMasterKey`: CloudFormation attaches the address and the new instance waits for it before database setup.

**A stack re-create is the risky path**: a fresh launch from a newer copy of the template defaults `BrochVersion` to the *latest* release — newer than your database if you have not upgraded since. It also generates a new master key unless you enter one. Before deleting the old stack, note its **Parameters** tab and enter that `BrochVersion` in the new one, and enter the master key you saved (see [The master key](#the-master-key)) as `BrochMasterKey`.

Where to find the version you were running: the (old) stack's **Parameters** tab when the box is dead (after a refused downgrade it can be lower than what ran; if you know that happened, use the higher version). When the box is alive, Admin → System is authoritative.

## Teardown

Note the stack's id before you delete it: the two secrets the delete keeps (below) carry it in their names.

```sh
STACK=broch
STACK_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackId' --output text)
ID=${STACK_ID##*/}    # the last "/" field of the StackId; keep it with your notes
aws cloudformation delete-stack --stack-name "$STACK"
```

The RDS instance is created with a `Snapshot` deletion policy — a final snapshot is taken on delete (`ExistingDatabase` deployments leave your DB untouched). In `Local` mode the on-box Postgres data volume likewise has a `Snapshot` deletion policy — a final EBS snapshot is taken on delete; to reuse that data, create the new stack with `DataVolumeSnapshotId` set to that snapshot (find it by its `<stack>-data` Name tag), `DataVolumeAz` set to the new subnet's AZ, `DataVolumeSize` at least the snapshot's size, the same `LocalDbAdminPassword` and `BrochVersion`, and the old stack's master key as `BrochMasterKey`.

**Two secrets stay.** Those final snapshots are useless without what decrypts and opens them, so `delete-stack` keeps:

- `<stack>-<id>/broch-master-key`, the master key (every database mode);
- `<stack>-<id>/broch-local-db-password`, the on-box Postgres password (`Local` mode only).

`<id>` is the `$ID` noted above. A first deploy that rolled back after creating them leaves them too (CloudFormation skips their delete), and so does deleting the rolled-back stack. Save both values before deleting: the master key with the `MasterKeyBackupCommand` output (see [The master key](#the-master-key)), the `Local` password as the [`Local` mode](#database-modes) description says. Delete the secrets yourself once you no longer need the snapshots, or once you have saved the values elsewhere. List exactly this stack's. The filter value includes the stack's unique id, so it already selects this stack only; the query repeats the check exactly (`starts_with` compares case-sensitively, where the name filter may not), as belt and braces before you delete anything:

```sh
aws secretsmanager list-secrets --filters Key=name,Values="$STACK-$ID/" \
  --query "SecretList[?starts_with(Name, '$STACK-$ID/')].[Name,ARN]" --output table
aws secretsmanager delete-secret --secret-id <each ARN from the list above> --recovery-window-in-days 7
```

`--recovery-window-in-days 7` (7 to 30) leaves a window in which `aws secretsmanager restore-secret` brings a secret back; `--force-delete-without-recovery` deletes it at once.

**Cleaning up later, without the id.** Each retained secret is named `<stack>-<id>/...`, with the id of the stack that made it (the 36 characters before the `/`). A secret is safe to delete only when no existing stack has that id, and only once you have saved what it holds or no longer need that stack's snapshots. Compare the two lists, region by region:

```sh
# The ids of every stack that still exists in this region (describe-stacks lists no deleted stack):
aws cloudformation describe-stacks --query 'Stacks[].StackId' --output text | tr '\t' '\n' | sed 's|.*/||'
# Every retained Broch secret in this region:
aws secretsmanager list-secrets \
  --query "SecretList[?ends_with(Name, '/broch-master-key') || ends_with(Name, '/broch-local-db-password')].[Name,ARN]" \
  --output table
```

A stack **upgraded from an older template version** in `Local` mode can also have a `<stack>/broch-local-db-password` entry with no id: the pre-upgrade password, kept when that upgrade replaced the secret, and possibly the one your data uses (see the [`Local` mode](#database-modes) description). It belongs to the stack name, not to one stack: the exact-stack list above doesn't show it, and in the list of every retained secret it is the one entry with no id, which the id comparison can't clear. Delete it the same way only once no stack of that name, and no snapshot you keep, uses that password.

The stack's other Secrets Manager entries are **deleted at once**: CloudFormation deletes them with no recovery window, on a stack delete and when an update removes one (for example switching a certificate from inline to a secret ARN). Neither a **redeploy under the same stack name** nor a retry after a rolled-back first deploy collides with the retained secrets: every secret name carries the stack instance's unique id, so the new stack gets fresh names. The deleted ones hold nothing a later deploy needs: the RDS master password belonged to the RDS instance the delete removed (a database restored from its final snapshot keeps that password, so set a new one with `aws rds modify-db-instance --master-user-password` before you use it), and with `ExistingServer` the `brochdb` database stays on your server, where the next stack's first boot sets the `broch` role's password again.

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
data-volume mount and device resolution) are live-deployed in CI on the stock Ubuntu AMI, with a
bring-your-own certificate given inline; `NewServer` with a supplied master key, `Local` with a generated one. Both lanes
also check that the Elastic IP is on the instance before its database traffic, and upgrade in place by a `BrochVersion` stack
update (metadata-only, same instance, healthy on the new version). Restoring `Local` from
`DataVolumeSnapshotId`, bringing your own Elastic IP, a certificate from your own Secrets Manager secrets
and its hourly renewal, and the downgrade and bad-tag guards are not exercised in CI.
