#!/usr/bin/env python3
"""Guard: every DnsAutoRecords=Auto `dynamic_dns { … }` block the VM appliances RENDER at
boot is a Caddyfile broch-caddy can actually parse. Cloud-free, token-free.

WHY THIS EXISTS. The appliances don't ship a static dynamic-dns.caddy: in
`DnsAutoRecords=Auto` mode (the DEFAULT) they GENERATE one at boot with a provider-specific
`printf` — azure-vm cloud-init `runcmd` (6 arms) and aws-vm render-secrets.sh subshell (3 arms).
That block is imported by the Caddyfile's GLOBAL OPTIONS block, so a malformed arm (unbalanced
brace, bad tab/newline, typo'd provider sub-key) means Caddy can't parse global options ->
Caddy never starts -> dead appliance on first deploy, with no deploy-time error and no CI catch.

WHAT ALREADY COVERS WHAT, AND THE GAP:
  - scripts/check-caddy-dns-sync.py (section 6) checks the auto-DNS WIRING (import/mount/module/
    seed-key parity) -- NOT the rendered block's syntax.
  - The azure/aws deploy DNS smokes prove render+boot end-to-end, but only for ONE provider each
    (Azure/Cloudflare, AWS/DigitalOcean), and only privately + token-gated. The other arms --
    Azure AzureDns/AzureDnsServicePrincipal/Route53/GoogleCloudDns/DigitalOcean and AWS Cloudflare/
    GoogleCloudDns -- render only on a real customer deploy, exercised nowhere in CI.

WHAT THIS DOES. For each arm it runs the EXACT `printf` the template runs (extracted from source,
not re-typed -- one source of truth, like check-caddy-dns-sync.py parses these same files), splices
the result into a minimal Caddyfile whose global options block imports it, and -- when
BROCH_CADDY_IMAGE is set -- runs `caddy adapt` inside that image (which has caddy-dynamicdns + all
libdns providers compiled in, so adapt INSTANTIATES the provider module and rejects a typo'd
sub-key; a stock caddy would reject `dynamic_dns` outright and prove nothing). Env placeholders
`{env.X}` need no real values -- adapt treats them as opaque. Without the image it still renders +
runs the static checks (arm coverage, credential-key parity, fail-closed gates, stub bytes), so it
is runnable anywhere; CI sets the image to add the adapt pass. Exit 0 = every arm valid, 1 = drift.

The credential-key parity here is the RENDER-side counterpart to check-caddy-dns-sync.py's CATALOG:
adapt validates block STRUCTURE but `{env.X}` is opaque to it, so a renamed/typo'd credential key
would still adapt -- this catches that.
"""
import os
import re
import subprocess
import sys
import tempfile

REPO = os.environ.get("REPO_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AZURE = f"{REPO}/bicep/azure-vm/cloud-init.yaml"
AWS = f"{REPO}/cloudformation/aws-vm/template.yaml"
MAIN_BICEP = f"{REPO}/bicep/azure-vm/main.bicep"
IMAGE = os.environ.get("BROCH_CADDY_IMAGE")  # e.g. ghcr.io/broch-io/broch-caddy:latest; unset => static-only

# Representative render inputs -- the apex case (no share subdomain): the "wildcard host IS the zone
# apex" default. The three %s in the shared TAIL are zone, apex label, wildcard label, in that order.
ZONE, APEX, STAR = "example.com", "@", "*"

# Each `<Label>) printf "<fmt>" "$zone" "$apex" "$star"` arm. The fmt embeds $TAIL/$tail (the shared
# domains+ip_source suffix), substituted before running. Non-greedy up to the first arg quote; the
# fmt contains no literal `"`, so this is unambiguous.
ARM_RE = re.compile(
    r'(?P<prov>\w+)\)\s+printf\s+"(?P<fmt>dynamic_dns \{.*?)"\s+'
    r'"\$(?:ZONE|zone)"\s+"\$(?:APEX|apex)"\s+"\$(?:STAR|star)"'
)
TAIL_RE = re.compile(r"(?m)^\s*(?:TAIL|tail)='(?P<tail>[^']*)'\s*$")

# provider Label -> (caddy libdns plugin, {credential env keys the block MUST reference}). Mirrors
# scripts/check-caddy-dns-sync.py CATALOG / *_EXPECT (keep in step). GOOGLE_APPLICATION_CREDENTIALS
# is a file path fed via GCP_PROJECT's sibling env, not referenced inside the block, so it's absent.
RENDER_EXPECT = {
    "Cloudflare":               ("cloudflare",     {"CLOUDFLARE_API_TOKEN"}),
    "AzureDns":                 ("azure",          {"AZURE_DNS_SUBSCRIPTION_ID", "AZURE_DNS_RESOURCE_GROUP"}),
    "AzureDnsServicePrincipal": ("azure",          {"AZURE_DNS_SUBSCRIPTION_ID", "AZURE_DNS_RESOURCE_GROUP",
                                                    "AZURE_DNS_TENANT_ID", "AZURE_DNS_CLIENT_ID", "AZURE_DNS_CLIENT_SECRET"}),
    "Route53":                  ("route53",        {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}),
    "GoogleCloudDns":           ("googleclouddns", {"GCP_PROJECT"}),
    "DigitalOcean":             ("digitalocean",   {"DO_AUTH_TOKEN"}),
}
# The arms each template is expected to carry -- a strict count/set match so a refactor that drops or
# renames an arm (silently rendering it uncovered) FAILS the guard instead of shrinking coverage.
AZURE_ARMS = {"Cloudflare", "AzureDns", "AzureDnsServicePrincipal", "Route53", "GoogleCloudDns", "DigitalOcean"}
AWS_ARMS = {"Cloudflare", "DigitalOcean", "GoogleCloudDns"}

errors, notes = [], []


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def env_refs(block):
    return set(re.findall(r"\{env\.([A-Z0-9_]+)\}", block))


def render(fmt, tail):
    """Reproduce the appliance's `printf "<fmt>" "$zone" "$apex" "$star"` via a POSIX sh printf
    (the same builtin cloud-init / Fn::Sub run at boot), so \\n / \\t / %s expand identically."""
    fmt = fmt.replace("$TAIL", tail).replace("$tail", tail)
    r = subprocess.run(
        ["sh", "-c", 'printf "$1" "$2" "$3" "$4"', "sh", fmt, ZONE, APEX, STAR],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"printf failed: {r.stderr.strip()}")
    return r.stdout


def wrapper(block):
    """A minimal Caddyfile that imports the rendered block the way the appliance Caddyfile does --
    inside the GLOBAL OPTIONS block. dynamic_dns is a global option; the trivial site just gives
    `caddy adapt` a server to build. This isolates exactly what can break (the rendered block)
    without dragging in tls.caddy / env the ddns arm has nothing to do with."""
    return "{\n" + block + "}\n\nhttp://localhost:8080 {\n\trespond \"ddns-adapt-probe\" 200\n}\n"


def parse_arms(path, label, expected):
    txt = read(path)
    tails = TAIL_RE.findall(txt)
    if len(tails) != 1:
        errors.append(f"{label}: expected exactly one TAIL/tail definition, found {len(tails)}")
        return {}
    tail = tails[0]
    arms = {m.group("prov"): m.group("fmt") for m in ARM_RE.finditer(txt)}
    if set(arms) != expected:
        errors.append(f"{label}: dynamic_dns arms {sorted(arms)} != expected {sorted(expected)} "
                      "(a dropped/renamed/reformatted arm would render uncovered -- update this guard "
                      "and check-caddy-dns-sync.py together)")
    return {prov: render(fmt, tail) for prov, fmt in arms.items()}


def check_block(label, prov, block):
    plugin, keys = RENDER_EXPECT[prov]
    if f"provider {plugin} " not in block and f"provider {plugin}\n" not in block:
        errors.append(f"{label}/{prov}: rendered block does not select `provider {plugin}`")
    got = env_refs(block)
    if got != keys:
        errors.append(f"{label}/{prov}: block env refs {sorted(got)} != expected {sorted(keys)} "
                      "(adapt can't catch a renamed credential key -- {env.X} is opaque to it)")


def adapt(outdir, name, text):
    """Write the wrapper and, if an image is configured, `caddy adapt` it inside broch-caddy."""
    path = os.path.join(outdir, f"{name}.caddy")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    if not IMAGE:
        return
    cmd = ["docker", "run", "--rm", "-v", f"{outdir}:/w:ro", "--entrypoint", "caddy", IMAGE,
           "adapt", "--adapter", "caddyfile", "--config", f"/w/{name}.caddy"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"caddy adapt FAILED for {name}:\n{r.stderr.strip() or r.stdout.strip()}")
    else:
        notes.append(f"caddy adapt OK: {name}")


# --- render every arm + adapt -----------------------------------------------------------------
outdir = os.environ.get("DDNS_RENDER_OUT") or tempfile.mkdtemp(prefix="ddns-render-")
targets = [("azure", AZURE, AZURE_ARMS), ("aws", AWS, AWS_ARMS)]
for plat, path, expected in targets:
    for prov, block in parse_arms(path, plat, expected).items():
        if prov not in RENDER_EXPECT:
            continue  # unrecognized arm: parse_arms already reported the coverage mismatch
        check_block(plat, prov, block)
        adapt(outdir, f"{plat}-{prov}", wrapper(block))

# --- fail-closed gates: the disabled paths must yield the empty comment stub, not a block -------
# azure: certMode=Byo forces effectiveDnsAuto=Manual in main.bicep, so the __DNS_AUTO_RECORDS__=Auto
# render is skipped and the write_files stub (a comment) stays. Assert both the coercion and the stub.
main_bicep = read(MAIN_BICEP)
if not re.search(r"effectiveDnsAuto\s*=\s*certMode\s*==\s*'Byo'\s*\?\s*'Manual'", main_bicep):
    errors.append("bicep/azure-vm/main.bicep: missing the `certMode == 'Byo' ? 'Manual'` coercion "
                  "(a Byo deploy must fall to Manual so no dynamic_dns block is rendered)")
AZURE_STUB = "# Automatic A-records disabled (dnsAutoRecords=Manual or Byo-cert). Manage DNS yourself."
if AZURE_STUB not in read(AZURE):
    errors.append(f"bicep/azure-vm/cloud-init.yaml: missing the disabled-mode stub `{AZURE_STUB}`")

# aws: the subshell renders ONLY when Auto AND CertMode!=Byo AND DnsProvider!=Route53 (Route53 gets
# native RecordSets). Byo/Route53/Manual keep the comment stub printed just above the subshell.
aws = read(AWS)
if not re.search(r'\[\s*"\$\{DnsAutoRecords\}"\s*=\s*"Auto"\s*\]\s*&&\s*'
                 r'\[\s*"\$\{CertMode\}"\s*!=\s*"Byo"\s*\]\s*&&\s*'
                 r'\[\s*"\$\{DnsProvider\}"\s*!=\s*"Route53"\s*\]', aws):
    errors.append("cloudformation/aws-vm/template.yaml: the auto-DNS render is not gated on "
                  "Auto && CertMode!=Byo && DnsProvider!=Route53 (fail-closed gate changed)")
AWS_STUB = "# Automatic A-records disabled (DnsAutoRecords=Manual/Byo, or Route53 native records). Manage DNS yourself."
if AWS_STUB not in aws:
    errors.append(f"cloudformation/aws-vm/template.yaml: missing the disabled-mode stub `{AWS_STUB}`")
# Both stubs are comment-only -> the imported global block must still adapt cleanly.
adapt(outdir, "azure-stub", wrapper(AZURE_STUB + "\n"))
adapt(outdir, "aws-stub", wrapper(AWS_STUB + "\n"))

if not errors:
    notes.append(f"{len(AZURE_ARMS)} azure + {len(AWS_ARMS)} aws render arms + 2 disabled stubs cover "
                 "every DnsAutoRecords path")

# --- report -----------------------------------------------------------------------------------
for n in notes:
    print(f"OK: {n}")
print(f"\nRendered wrappers in {outdir}" + ("" if IMAGE else " (BROCH_CADDY_IMAGE unset -> static checks only, no caddy adapt)"))
if errors:
    print()
    for e in errors:
        print(f"::error::{e}")
    print(f"\nauto-DNS render check: {len(errors)} issue(s). Every DnsAutoRecords=Auto arm must render "
          "a `dynamic_dns` block broch-caddy can parse, and the disabled paths must yield the empty stub.")
    sys.exit(1)
print("OK: every rendered dynamic_dns arm is valid Caddyfile; disabled paths yield the empty stub.")
sys.exit(0)
