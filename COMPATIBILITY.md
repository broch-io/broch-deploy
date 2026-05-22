# Compatibility matrix

Which version of this repo to use with which Broch server release.

## How this works

Examples in `main` track the **current stable** Broch server release. When something in the examples needs to change for a new server version (renamed env var, new required resource, etc.), we cut a git tag *before* making the change. That tag captures the last working examples for the prior server version.

To use an older state of the examples:

```sh
git clone https://github.com/broch-io/broch-deploy.git
cd broch-deploy
git checkout broch-v1.2.x   # or whichever tag matches your server version
```

## Matrix

| Examples ref | Supported Broch server versions | Notes                         |
| ------------ | ------------------------------- | ----------------------------- |
| `main`       | Latest stable                   | Tracks the current release.   |

This matrix grows as we cut tags. Until then, `main` is the only ref you need.

## What counts as a "breaking change" for examples

We tag (and start a new matrix row) when any of these change:

- Image registry path or name (e.g. moving off `ghcr.io/broch-io/broch`)
- Required env vars renamed, added, or removed
- Required external resources (Postgres major version bump, new managed-cert source, etc.)
- Default port or protocol changes
- Anything that would cause `docker-compose up` or `terraform apply` to fail against the previously-working example

We do **not** tag for:

- Internal server changes that don't surface in deployment config
- New optional env vars (backward-compatible)
- Documentation-only updates
- New example platforms

The goal is: if your existing server version still runs against `main`'s examples, no new tag is needed.
