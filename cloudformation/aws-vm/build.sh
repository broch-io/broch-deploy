#!/usr/bin/env bash
# Build the deployable CloudFormation template by embedding the canonical assets
# VERBATIM into template.yaml's UserData — the AWS analog of main.bicep's
# loadTextContent(). The VM then runs byte-for-byte the same stack a docker-direct
# customer runs. Embeds the shared docker-compose plus BOTH Caddyfiles:
#   - with-postgres-external/Caddyfile  -> Auto mode (ACME DNS-01)
#   - with-postgres-byo-cert/Caddyfile  -> Byo  mode (static cert)
# CertMode selects which one is written at deploy time.
#
#   ./build.sh            -> dist/template.yaml
#
# Deploy dist/template.yaml (NOT the source template.yaml, which carries placeholders).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
auto="$here/../../docker-compose/with-postgres-external"
byo="$here/../../docker-compose/with-postgres-byo-cert"
tls="$here/../../docker-compose/caddy-tls"
out="$here/dist"
mkdir -p "$out"

# `base64 -w0` is GNU-only (BSD/macOS base64 rejects -w and wraps at 76 cols,
# producing malformed single-line YAML scalars). `| tr -d '\n'` strips the wrapping
# portably on both GNU and BSD.
compose_b64="$(base64 "$auto/docker-compose.yml" | tr -d '\n')"
caddyfile_auto_b64="$(base64 "$auto/Caddyfile" | tr -d '\n')"
caddyfile_byo_b64="$(base64 "$byo/Caddyfile" | tr -d '\n')"

# Per-provider tls fragments from the canonical single source (docker-compose/caddy-tls/). The
# template selects one at boot by DnsProvider and base64-decodes it to /opt/broch/tls.caddy. Route53
# uses the instance-role variant (no keys). Azure DNS is intentionally absent -- the AWS appliance's
# DnsProvider AllowedValues don't include it.
tls_cloudflare_b64="$(base64 "$tls/cloudflare.caddy" | tr -d '\n')"
tls_route53_b64="$(base64 "$tls/route53-iam.caddy" | tr -d '\n')"
tls_digitalocean_b64="$(base64 "$tls/digitalocean.caddy" | tr -d '\n')"
tls_googleclouddns_b64="$(base64 "$tls/googleclouddns.caddy" | tr -d '\n')"

# Substitute the placeholders. Python avoids sed-delimiter clashes with the
# +/= in base64 and keeps each blob on a single line.
COMPOSE_B64="$compose_b64" \
CADDYFILE_AUTO_B64="$caddyfile_auto_b64" \
CADDYFILE_BYO_B64="$caddyfile_byo_b64" \
TLS_CLOUDFLARE_B64="$tls_cloudflare_b64" \
TLS_ROUTE53_B64="$tls_route53_b64" \
TLS_DIGITALOCEAN_B64="$tls_digitalocean_b64" \
TLS_GOOGLECLOUDDNS_B64="$tls_googleclouddns_b64" \
python3 - "$here/template.yaml" "$out/template.yaml" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for placeholder, env in (
    ("__COMPOSE_B64__", "COMPOSE_B64"),
    ("__CADDYFILE_AUTO_B64__", "CADDYFILE_AUTO_B64"),
    ("__CADDYFILE_BYO_B64__", "CADDYFILE_BYO_B64"),
    ("__TLS_CLOUDFLARE_B64__", "TLS_CLOUDFLARE_B64"),
    ("__TLS_ROUTE53_B64__", "TLS_ROUTE53_B64"),
    ("__TLS_DIGITALOCEAN_B64__", "TLS_DIGITALOCEAN_B64"),
    ("__TLS_GOOGLECLOUDDNS_B64__", "TLS_GOOGLECLOUDDNS_B64"),
):
    if placeholder not in text:
        sys.exit(f"placeholder not found in template: {placeholder}")
    text = text.replace(placeholder, os.environ[env])
open(dst, "w").write(text)
print(f"wrote {dst}")
PY
