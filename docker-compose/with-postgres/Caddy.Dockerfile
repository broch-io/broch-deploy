# Caddy with the Cloudflare DNS provider module compiled in.
#
# The stock caddy:2 image only ships with the HTTP-01 ACME challenge, which
# can't issue wildcard certs. Broch needs wildcard TLS for tunnel subdomains,
# so we use DNS-01 — which means baking the DNS provider module into the
# Caddy binary via xcaddy.
#
# To use a different DNS provider, replace `caddy-dns/cloudflare` with the
# module for your provider:
#   - github.com/caddy-dns/route53      (AWS)
#   - github.com/caddy-dns/googleclouddns
#   - github.com/caddy-dns/gandi
#   - github.com/caddy-dns/digitalocean
#   - github.com/caddy-dns/hetzner
# Full list: https://github.com/orgs/caddy-dns/repositories

FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
