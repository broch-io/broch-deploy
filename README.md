# broch-deploy

Deployment examples for self-hosting the [Broch](https://broch.io) SSH tunnel server.

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
│   └── azure-container-apps/         # Azure Container Apps + Postgres sidecar.
├── cloudformation/
│   └── aws-vm/                       # AWS VM appliance — single EC2 + Route 53 DNS-01 via instance role + optional RDS.
├── terraform/
│   ├── digitalocean/                 # Droplet + Docker Compose + Caddy + block storage.
│   ├── aws-ecs/                      # AWS Fargate + ALB + RDS Postgres + Secrets Manager (experimental).
│   └── azure-container-apps/         # Azure Container Apps + Postgres Flexible + Key Vault.
└── CHANGELOG.md                      # What changed in each Broch server release.
```

Pick the directory that matches where you want to run Broch. Each has its own README with `make`-style commands and the env vars you'll need to fill in.

## The Broch server image

```text
ghcr.io/broch-io/broch:<version>
```

The image is a public GHCR package — pull it directly, no authentication needed:

```sh
docker pull ghcr.io/broch-io/broch:1.26.0
```

Available tags follow semver (`1.26.0`, `1.26`, `1`, `latest`). For production we recommend pinning to a specific version (`ghcr.io/broch-io/broch:1.26.0`) rather than `:latest` — every example here ships pinned.

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
| Production on Azure (Container Apps + Postgres Flexible)      | [`terraform/azure-container-apps/`](terraform/azure-container-apps/)         |
| Azure Container Apps with Bicep (sidecar Postgres)            | [`bicep/azure-container-apps/`](bicep/azure-container-apps/)                 |
| AWS on Fargate (experimental — see note below)                | [`terraform/aws-ecs/`](terraform/aws-ecs/)                                   |

The two **VM appliances** (`bicep/azure-vm`, `cloudformation/aws-vm`) are the most turnkey shapes: a single deployment that runs the canonical docker-compose stack verbatim on one VM, with secrets kept out of user data (Key Vault / Secrets Manager) and wildcard TLS issued automatically via ACME DNS-01. For Azure Container Apps there are two options: the **Terraform** module provisions managed Postgres Flexible Server + Key Vault for a scale-out shape; the **Bicep** module is the self-contained single-replica stack (Postgres sidecar).

> **`terraform/aws-ecs` is experimental** — a working starting point, not a supported production path. For a supported AWS deployment use the [`cloudformation/aws-vm/`](cloudformation/aws-vm/) appliance.

Every example uses the same dependency footprint — broch needs Postgres (the only supported database), an identity provider, and a wildcard hostname. Every example is public-facing and terminates TLS. A Broch license is activated in-app after first sign-in, not supplied at boot. The examples differ along two axes:

- **TLS source**: Caddy ACME (auto), BYO cert (manual rotation), or cloud-managed cert (AWS ACM / Azure managed)
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
