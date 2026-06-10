# broch-deploy

Deployment examples for self-hosting the [Broch](https://broch.io) SSH tunnel server.

If you're looking for **the application** itself, the public docs at <https://broch.io/docs> are the entry point. This repo is for the people running it on their own infrastructure — Dockerfiles, Terraform modules, compose files, all version-aware.

## What's in here

```text
broch-deploy/
├── docker-compose/
│   ├── with-postgres/                # broch + Postgres + Caddy auto-TLS. Public-internet use.
│   ├── with-postgres-external/       # broch + Caddy + external managed Postgres.
│   └── with-postgres-byo-cert/       # broch + Postgres + Caddy serving a cert YOU provide.
├── terraform/
│   ├── digitalocean/                 # Droplet + Docker Compose + Caddy + block storage.
│   ├── aws-ecs/                      # AWS Fargate + ALB + RDS Postgres + Secrets Manager.
│   └── azure-container-apps/         # Azure Container Apps + Postgres Flexible + Key Vault.
├── bicep/
│   └── azure-container-apps/         # Azure Container Apps + Postgres sidecar. What Broch runs.
└── COMPATIBILITY.md                  # Which examples support which Broch server versions.
```

Pick the directory that matches where you want to run Broch. Each has its own README with `make`-style commands and the env vars you'll need to fill in.

## The Broch server image

```text
ghcr.io/broch-io/broch:<version>
```

The image is a public GHCR package — pull it directly, no authentication needed:

```sh
docker pull ghcr.io/broch-io/broch:1.5.0
```

Available tags follow semver (`1.5.0`, `1.5`, `1`, `latest`). For production we recommend pinning to a specific version (`ghcr.io/broch-io/broch:1.5.0`) rather than `:latest`.

## Picking an example

| Goal                                                          | Use                                                                          |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Single-VM Broch on the public internet (Caddy auto-TLS)       | [`docker-compose/with-postgres/`](docker-compose/with-postgres/)             |
| Same as above but Broch points at a managed/external Postgres | [`docker-compose/with-postgres-external/`](docker-compose/with-postgres-external/) |
| Same as above but with a wildcard cert YOU provide            | [`docker-compose/with-postgres-byo-cert/`](docker-compose/with-postgres-byo-cert/) |
| Production on DigitalOcean (Droplet + Docker Compose + Caddy) | [`terraform/digitalocean/`](terraform/digitalocean/)                         |
| Production on AWS (Fargate + ALB + RDS)                       | [`terraform/aws-ecs/`](terraform/aws-ecs/)                                   |
| Production on Azure (Container Apps + Postgres Flexible)      | [`terraform/azure-container-apps/`](terraform/azure-container-apps/)         |
| Azure with Bicep instead of Terraform (sidecar Postgres)      | [`bicep/azure-container-apps/`](bicep/azure-container-apps/)                 |

Two Azure options: the **Terraform** module provisions managed Postgres Flexible Server + Key Vault for a scale-out, HA shape; the **Bicep** module is the self-contained single-replica stack (Postgres sidecar) that Broch, LLC runs for its own deployments. Pick Terraform for managed Postgres and scale, Bicep for the smallest footprint or to match exactly what we run.

> **`terraform/aws-ecs` is experimental.** AWS isn't part of the current supported deploy set — the module is provided as a working starting point, not a supported production path. The docker-compose and Azure/DigitalOcean examples are the supported options today.

Every example uses the same dependency footprint — broch needs Postgres (the only supported database), an identity provider, and a wildcard hostname. Every example is public-facing and terminates TLS. A Broch license is activated in-app after first sign-in, not supplied at boot. The examples differ along two axes:

- **TLS source**: Caddy ACME (auto), BYO cert (manual rotation), or cloud-managed cert (AWS ACM / Azure managed)
- **Infrastructure layer**: single VM (docker-compose, DigitalOcean Droplet) vs. managed cloud services (ECS Fargate, Azure Container Apps)

For other platforms (GCP, on-prem Kubernetes, Hetzner) the docker-compose examples translate cleanly — `with-postgres` is a complete production-shape stack that you can `scp` to any Linux VM.

## Version compatibility

Examples in `main` track the **current stable** Broch server release. If you're running an older version, check the [compatibility matrix](COMPATIBILITY.md) and either:

- Read the matrix to confirm your version is still in the supported range for `main`, or
- Check out an older git tag (e.g. `git checkout broch-v1.2.x`) to get the examples that matched that release.

We deliberately don't duplicate examples per version — most things stay the same release-to-release. The matrix tells you when something materially changed.

## Contributing

Found a bug in an example, or want to contribute a new platform? PRs welcome. Examples should be:

- **Minimal** — only the env vars and resources Broch needs, nothing extra.
- **Version-pinned** — every example pins the Broch image to a concrete version, not `:latest`.
- **Documented** — each example dir has a README explaining what it deploys and what the user has to fill in.

## License

MIT — see [LICENSE](LICENSE).
