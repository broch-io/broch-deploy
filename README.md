# broch-deploy

Deployment examples for self-hosting the [Broch](https://broch.io) SSH tunnel server.

If you're looking for **the application** itself, the public docs at <https://broch.io/docs> are the entry point. This repo is for the people running it on their own infrastructure — Dockerfiles, Terraform modules, compose files, all version-aware.

## What's in here

```text
broch-deploy/
├── docker-compose/
│   ├── single-host/         # All-in-one: broch + sqlite, no TLS. For kicking tires.
│   └── with-postgres/       # broch + Postgres + Caddy (auto-TLS via Let's Encrypt).
├── terraform/
│   ├── aws-ecs/             # AWS Fargate + ALB + RDS Postgres + Secrets Manager.
│   └── azure-container-apps/# Azure Container Apps + Postgres Flexible Server + Key Vault.
└── COMPATIBILITY.md         # Which examples support which Broch server versions.
```

Pick the directory that matches where you want to run Broch. Each has its own README with `make`-style commands and the env vars you'll need to fill in.

## The Broch server image

```text
ghcr.io/broch-io/broch:<version>
```

> **The image is currently a private GHCR package.** To pull, you need a
> GitHub Personal Access Token with the `read:packages` scope, then
> `docker login ghcr.io -u <github-user>` once. This repo and the image
> will both become public in a future release; until then, treat both as
> internal/customer-shared artifacts.

```sh
echo $GITHUB_PAT | docker login ghcr.io -u <github-user> --password-stdin
docker pull ghcr.io/broch-io/broch:1.5.0
```

Available tags follow semver (`1.5.0`, `1.5`, `1`, `latest`). For production we recommend pinning to a specific version (`ghcr.io/broch-io/broch:1.5.0`) rather than `:latest`.

## Picking an example

| Goal                                       | Use                                                            |
| ------------------------------------------ | -------------------------------------------------------------- |
| Try Broch locally on a laptop              | [`docker-compose/single-host/`](docker-compose/single-host/)   |
| Small production deployment on a single VM | [`docker-compose/with-postgres/`](docker-compose/with-postgres/) |
| AWS production deployment                  | [`terraform/aws-ecs/`](terraform/aws-ecs/)                     |
| Azure production deployment                | [`terraform/azure-container-apps/`](terraform/azure-container-apps/) |

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
