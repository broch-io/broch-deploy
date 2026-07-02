# Canonical Caddy DNS-01 TLS fragments (single source of truth)

Each `<provider>.caddy` is the complete Caddy `tls { … }` block for one ACME DNS-01 provider, with
the propagation tuning baked in (`resolvers` + `propagation_timeout` on every provider; a
`propagation_delay` floor only on the slow ones — route53 60s, digitalocean 120s).

**This is the ONE place these fragments are defined.** Every deploy target consumes them rather than
re-typing the block:

| Target | how it consumes the fragment |
| --- | --- |
| `bicep/azure-vm` | `loadTextContent()` each fragment, ternary-select by `dnsProvider` |
| `cloudformation/aws-vm` | `build.sh` base64-embeds them; the template selects one per `DnsProvider` (route53 uses `route53-iam.caddy` — the AWS VM authenticates Route 53 with its **instance role**, no keys) |
| `terraform/digitalocean` | `templatefile` reads the selected fragment (digitalocean/cloudflare/godaddy) |
| `docker-compose/*/tls.caddy` | the active block is `cloudflare.caddy`, verbatim |

`scripts/check-caddy-dns-sync.py` (the `caddy DNS-01 provider block sync` CI job) fails the build if
any target drifts from these files — so a change here must be reflected everywhere, and vice versa.

Two Route 53 variants exist on purpose: `route53.caddy` (explicit `{env.AWS_*}` keys, for a
docker-direct / bicep deploy) and `route53-iam.caddy` (bare `dns route53`, for the AWS VM appliance
whose instance role supplies credentials via IMDS). `CertMode=Byo` has no fragment here — it is not a
DNS-01 provider; the supplied cert is set directly in the Byo Caddyfile.
