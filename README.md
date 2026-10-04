# broch-deploy

Deployment examples for self-hosting the [Broch](https://broch.io) identity-aware tunnel server.

If you're looking for **the application** itself, the public docs at <https://broch.io/docs> are the entry point. This repo is for the people running it on their own infrastructure — Dockerfiles, Terraform modules, compose files, all version-aware.

## What's in here

```text
broch-deploy/
├── docker-compose/
│   ├── with-postgres/                # broch + Postgres + Caddy auto-TLS. Public-internet use.
│   ├── with-postgres-external/       # broch + Caddy + external managed Postgres.
│   ├── with-postgres-byo-cert/       # broch + Postgres + Caddy serving a cert YOU provide.
│   └── caddy-tls/                    # Canonical per-provider Caddy DNS-01 fragments (shared by every target).
├── bicep/
│   ├── azure-vm/                     # Azure VM appliance — single VM + Key Vault + optional managed Postgres.
│   └── azure-container-apps/         # Azure Container Apps + Postgres sidecar (evaluation) or managed Postgres.
├── cloudformation/
│   └── aws-vm/                       # AWS VM appliance — single EC2 + Route 53 DNS-01 via instance role + optional RDS.
├── terraform/
│   ├── digitalocean/                 # Droplet + Docker Compose + Caddy + block storage.
│   ├── aws-ecs/                      # AWS Fargate + ALB + RDS Postgres + Secrets Manager (beta).
│   └── azure-container-apps/         # Azure Container Apps + Postgres Flexible + Key Vault (beta).
└── CHANGELOG.md                      # What changed in each Broch server release.
```

Pick the directory that matches where you want to run Broch. Each has its own README with the commands to deploy it and the values you'll need to fill in.

## The Broch server image

```text
ghcr.io/broch-io/broch:<version>
```

The image is a public GHCR package — pull it directly, no authentication needed:

```sh
docker pull ghcr.io/broch-io/broch:1.35.0
```

Each release is tagged with its full version (`X.Y.Z`); `latest` points at the newest release. For production we recommend pinning to a specific version, as above, rather than `:latest` — every example here ships pinned.

Broch publishes supported releases. Superseded versions are purged — pin to a current release and upgrade as new ones ship; the [changelog](CHANGELOG.md) records what changed in each release, including anything that affects an upgrade.

## Picking an example

| Goal                                                          | Use                                                                          |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Single-VM Broch on the public internet (Caddy auto-TLS)       | [`docker-compose/with-postgres/`](docker-compose/with-postgres/)             |
| Same as above but Broch points at a managed/external Postgres | [`docker-compose/with-postgres-external/`](docker-compose/with-postgres-external/) |
| Same as above but with a wildcard cert YOU provide            | [`docker-compose/with-postgres-byo-cert/`](docker-compose/with-postgres-byo-cert/) |
| **VM appliance on Azure** (one deploy: VM + Key Vault + wildcard TLS; optional managed Postgres) | [`bicep/azure-vm/`](bicep/azure-vm/)         |
| **VM appliance on AWS** (one stack: EC2 + Route 53 DNS-01 via the instance role; optional RDS)   | [`cloudformation/aws-vm/`](cloudformation/aws-vm/) |
| Production on DigitalOcean (Droplet + Docker Compose + Caddy) | [`terraform/digitalocean/`](terraform/digitalocean/)                         |
| Azure Container Apps + Postgres Flexible (beta — see note below) | [`terraform/azure-container-apps/`](terraform/azure-container-apps/)         |
| Azure Container Apps with Bicep (sidecar or managed Postgres) | [`bicep/azure-container-apps/`](bicep/azure-container-apps/)                 |
| AWS on Fargate (beta — see note below)                        | [`terraform/aws-ecs/`](terraform/aws-ecs/)                                   |

The two **VM appliances** (`bicep/azure-vm`, `cloudformation/aws-vm`) are the most turnkey shapes: a single deployment that runs the canonical docker-compose stack verbatim on one VM, with secrets kept out of user data (Key Vault / Secrets Manager) and wildcard TLS issued automatically via ACME DNS-01. For Azure Container Apps there are two options: the **Terraform** module (beta) provisions managed Postgres Flexible Server + Key Vault; the **Bicep** template runs one replica with a Postgres sidecar for evaluation, or with a provisioned Flexible Server or your own Postgres for production, its secrets inline in the app's configuration rather than in Key Vault.

> **`terraform/azure-container-apps` and `terraform/aws-ecs` are beta** — working starting points that automation exercises less than the VM appliances. Test them before you rely on them, or use the [`bicep/azure-vm/`](bicep/azure-vm/) or [`cloudformation/aws-vm/`](cloudformation/aws-vm/) appliance.

Every example uses the same dependency footprint — broch needs Postgres (the only supported database), an identity provider, and a wildcard hostname. Every example is public-facing and terminates TLS. A Broch license is activated in-app after first sign-in, not supplied at boot. The examples differ along two axes:

- **TLS source**: Caddy ACME (auto), BYO cert (manual rotation; Azure Container Apps needs a wildcard you provide, since Azure's managed certificates don't issue wildcards), or an AWS ACM cert (ECS Fargate)
- **Infrastructure layer**: single VM (docker-compose, the Azure/AWS VM appliances, DigitalOcean Droplet) vs. managed cloud services (ECS Fargate, Azure Container Apps)

For other platforms (GCP, on-prem Kubernetes, Hetzner) the docker-compose examples translate cleanly — `with-postgres` is a complete production-shape stack that you can `scp` to any Linux VM.

## Version compatibility

Examples in `main` track the **current stable** Broch server release, and Broch purges superseded images — so pinning to a current release and keeping up is the supported path. We don't duplicate examples per version; most things stay the same release-to-release, and when something deployment-affecting does change (a renamed env var, a new required resource), it's called out in the [changelog](CHANGELOG.md)'s **Deploy impact** section.

## Contributing

Found a bug in an example, or want to contribute a new platform? PRs welcome. Examples should be:

- **Minimal** — only the env vars and resources Broch needs, nothing extra.
- **Version-pinned** — every example pins the Broch image to a concrete version, not `:latest`.
- **Documented** — each example dir has a README explaining what it deploys and what the user has to fill in.

## License

MIT — see [LICENSE](LICENSE).
