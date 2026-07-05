# Caddy with the major DNS-provider modules compiled in (for ACME DNS-01).
#
# The stock caddy:2 image only ships the HTTP-01 challenge, which can't issue
# wildcard certs. Broch needs wildcard TLS for tunnel subdomains, so we use
# DNS-01 — which means baking the DNS-provider modules into the binary via
# xcaddy. The ACTIVE provider is selected at runtime in tls.caddy, so one image
# serves any of these without a rebuild.
#
# Need a provider not listed here? Add it from
# https://github.com/orgs/caddy-dns/repositories and rebuild.
#
# Must stay in sync with the shipped ghcr.io/broch-io/broch-caddy image: the
# Caddyfile's global options block imports
# dynamic-dns.caddy, which — in DnsAutoRecords=Auto — uses the `dynamic_dns` option
# from caddy-dynamicdns. Without that module compiled in, Caddy fails to parse the
# global block and won't start. So this escape-hatch build MUST include it too.

FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/caddy-dns/azure \
    --with github.com/caddy-dns/route53 \
    --with github.com/caddy-dns/googleclouddns \
    --with github.com/caddy-dns/digitalocean \
    --with github.com/mholt/caddy-dynamicdns

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
