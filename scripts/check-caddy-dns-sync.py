#!/usr/bin/env python3
"""Guard: the Caddy DNS-01 provider config has ONE source, and every target loads the RIGHT fragment.

`docker-compose/caddy-tls/<provider>.caddy` is the single source of truth for each provider's Caddy
`tls { dns <provider> ... }` block + DNS-01 propagation tuning. Every deploy target consumes those
fragments rather than re-typing the block:

  - docker-compose/*/tls.caddy               -> active block IS cloudflare.caddy
  - bicep/azure-vm/main.bicep                -> loadTextContent(... caddy-tls/<f>.caddy), ternary-select
  - cloudformation/aws-vm/build.sh+template  -> base64-embeds the fragments, selects one at boot
  - terraform/digitalocean/{main.tf,cloud-init.yaml} -> templatefile reads the selected fragment

Each target selects its provider at a different layer (a bicep ternary, a boot-time shell case in
the CFN template, a Terraform lookup), and most provider paths are not exercised by a live deploy
on every change -- so this guard checks CORRESPONDENCE, not just presence: every target must select
the fragment whose (plugin, credential env keys) match the provider it is wiring, including the two
Route 53 variants. Pure static, no cloud. Exit 0 = in sync, 1 = drift.

CANONICAL CATALOG -- the single source of truth this guard validates every target against. A new
fragment / provider must be added here (and to each target) together, or the guard fails.
"""
import os
import re
import sys

REPO = os.environ.get("REPO_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TLS_DIR = f"{REPO}/docker-compose/caddy-tls"
WP = f"{REPO}/docker-compose/with-postgres/docker-compose.yml"
WPE = f"{REPO}/docker-compose/with-postgres-external/docker-compose.yml"
WP_TLS = f"{REPO}/docker-compose/with-postgres/tls.caddy"
WPE_TLS = f"{REPO}/docker-compose/with-postgres-external/tls.caddy"
BICEP = f"{REPO}/bicep/azure-vm/main.bicep"
BUILD = f"{REPO}/cloudformation/aws-vm/build.sh"
CFN = f"{REPO}/cloudformation/aws-vm/template.yaml"
DO_MAIN = f"{REPO}/terraform/digitalocean/main.tf"
DO_VARS = f"{REPO}/terraform/digitalocean/variables.tf"
DO_CLOUDINIT = f"{REPO}/terraform/digitalocean/cloud-init.yaml"

RESOLVERS = "resolvers 1.1.1.1 8.8.8.8"
PROP_TIMEOUT = "propagation_timeout 300s"
# Caddy dns plugin -> required propagation_delay FLOOR (slow providers only).
SLOW_DELAY = {"route53": "propagation_delay 60s", "digitalocean": "propagation_delay 120s"}

# fragment file -> (Caddy dns plugin, frozenset of {env.*} credential keys the block must reference).
# GOOGLE_APPLICATION_CREDENTIALS is a file path (not read inside the tls block), so it's not here.
CATALOG = {
    "cloudflare.caddy":     ("cloudflare",     frozenset({"CLOUDFLARE_API_TOKEN"})),
    "route53.caddy":        ("route53",        frozenset({"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"})),
    "route53-iam.caddy":    ("route53",        frozenset()),  # bare 'dns route53' -- instance role
    "azure-mi.caddy":       ("azure",          frozenset({"AZURE_DNS_SUBSCRIPTION_ID", "AZURE_DNS_RESOURCE_GROUP"})),
    "azure-spn.caddy":      ("azure",          frozenset({"AZURE_DNS_SUBSCRIPTION_ID", "AZURE_DNS_RESOURCE_GROUP",
                                                          "AZURE_DNS_TENANT_ID", "AZURE_DNS_CLIENT_ID", "AZURE_DNS_CLIENT_SECRET"})),
    "googleclouddns.caddy": ("googleclouddns", frozenset({"GCP_PROJECT"})),
    "digitalocean.caddy":   ("digitalocean",   frozenset({"DO_AUTH_TOKEN"})),
    "godaddy.caddy":        ("godaddy",        frozenset({"GODADDY_API_TOKEN"})),
}

# Which fragment each target's provider selector MUST resolve to (pins the route53 / azure variants).
BICEP_EXPECT = {  # dnsProvider param value -> fragment file (explicit-keys route53: Azure VM has no instance role)
    "Cloudflare": "cloudflare.caddy", "AzureDns": "azure-mi.caddy",
    "AzureDnsServicePrincipal": "azure-spn.caddy", "Route53": "route53.caddy",
    "GoogleCloudDns": "googleclouddns.caddy", "DigitalOcean": "digitalocean.caddy",
}
CFN_EXPECT = {  # DnsProvider value -> (build.sh var suffix, __PLACEHOLDER__, fragment file). route53 = instance role.
    "Cloudflare":     ("cloudflare",     "__TLS_CLOUDFLARE_B64__",     "cloudflare.caddy"),
    "DigitalOcean":   ("digitalocean",   "__TLS_DIGITALOCEAN_B64__",   "digitalocean.caddy"),
    "GoogleCloudDns": ("googleclouddns", "__TLS_GOOGLECLOUDDNS_B64__", "googleclouddns.caddy"),
    "Route53":        ("route53",        "__TLS_ROUTE53_B64__",        "route53-iam.caddy"),
}

errors, notes = [], []


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def env_refs(block):
    return frozenset(re.findall(r"\{env\.([A-Z0-9_]+)\}", block))


# --- 1. POLICY + CATALOG: the fragment dir is exactly the catalog, each fragment conforms ---------
present = {f for f in os.listdir(TLS_DIR) if f.endswith(".caddy")}
for extra in sorted(present - set(CATALOG)):
    errors.append(f"caddy-tls/{extra}: fragment not in the guard CATALOG (add it, with its plugin+env keys)")
for miss in sorted(set(CATALOG) - present):
    errors.append(f"caddy-tls/{miss}: CATALOG fragment missing from the directory")

for fname, (plugin, keys) in CATALOG.items():
    if fname not in present:
        continue
    block = read(f"{TLS_DIR}/{fname}")
    label = f"caddy-tls/{fname}"
    got = re.search(r"\bdns\s+([A-Za-z0-9]+)", block)
    if not got or got.group(1) != plugin:
        errors.append(f"{label}: expected 'dns {plugin}', found {got.group(1) if got else 'no dns directive'}")
    if env_refs(block) != keys:
        errors.append(f"{label}: env refs {sorted(env_refs(block))} != expected {sorted(keys)}")
    if RESOLVERS not in block:
        errors.append(f"{label}: missing '{RESOLVERS}'")
    if PROP_TIMEOUT not in block:
        errors.append(f"{label}: missing '{PROP_TIMEOUT}'")
    if plugin in SLOW_DELAY:
        if SLOW_DELAY[plugin] not in block:
            errors.append(f"{label}: slow provider '{plugin}' needs '{SLOW_DELAY[plugin]}'")
    elif "propagation_delay" in block:
        errors.append(f"{label}: fast provider '{plugin}' must NOT set propagation_delay")
if not errors:
    notes.append(f"{len(CATALOG)} fragments conform to the catalog (plugin + env keys + tuning)")


# --- 2. bicep: each dnsProvider selects the RIGHT fragment (variant-pinned), none inlined ---------
bicep_txt = read(BICEP)
if re.search(r"var\s+tls[A-Za-z0-9]*\s*=\s*'tls\s*\{", bicep_txt):
    errors.append("bicep/azure-vm: re-inlines a tls{...} literal -- must loadTextContent the fragment")
b_var2file = dict(re.findall(r"var\s+(tls[A-Za-z0-9]+)\s*=\s*loadTextContent\('\.\./\.\./docker-compose/caddy-tls/([\w.-]+)'\)", bicep_txt))
# the autoTlsCaddy ternary: dnsProvider == 'X' ? tlsY  (+ a trailing else var for the last provider)
auto = re.search(r"var\s+autoTlsCaddy\s*=\s*(.+)", bicep_txt)
b_prov2var = dict(re.findall(r"dnsProvider\s*==\s*'(\w+)'\s*\?\s*(tls[A-Za-z0-9]+)", auto.group(1) if auto else ""))
else_var = re.search(r":\s*(tls[A-Za-z0-9]+)\)+\s*$", auto.group(1)) if auto else None
if else_var:  # the final else is the provider NOT matched by a `dnsProvider ==` test
    matched = set(b_prov2var)
    unmatched = [p for p in BICEP_EXPECT if p not in matched]
    if len(unmatched) == 1:
        b_prov2var[unmatched[0]] = else_var.group(1)
for prov, want_file in BICEP_EXPECT.items():
    var = b_prov2var.get(prov)
    got_file = b_var2file.get(var) if var else None
    if got_file != want_file:
        errors.append(f"bicep/azure-vm: dnsProvider '{prov}' selects {got_file or var or '???'}, expected {want_file}")
if not any("bicep" in e for e in errors):
    notes.append("bicep selects the correct fragment for all 6 providers (route53 = explicit keys)")


# --- 3. CFN: build.sh embeds the right fragments; template selects them; placeholder sets match ---
build_txt, cfn_txt = read(BUILD), read(CFN)
c_var2file = dict(re.findall(r'tls_(\w+)_b64="\$\(base64 "\$tls/([\w.-]+)"', build_txt))
# placeholders build.sh actually substitutes (python loop) vs placeholders present in the template
build_ph = set(re.findall(r'\("(__TLS_\w+__)",\s*"\w+"\)', build_txt))
tmpl_ph = set(re.findall(r"__TLS_\w+_B64__", cfn_txt))
if build_ph != tmpl_ph:
    errors.append(f"cloudformation/aws-vm: build.sh placeholders {sorted(build_ph)} != template "
                  f"placeholders {sorted(tmpl_ph)} -- a template __TLS_*__ would ship unsubstituted")
# each DnsProvider case must be the base64-decode shape selecting the RIGHT placeholder+fragment
c_case = dict(re.findall(r"(\w+)\)\s*printf\s+'%s'\s+'(__TLS_\w+_B64__)'\s*\|\s*base64\s+-d", cfn_txt))
c_default = re.search(r"\*\)\s*printf\s+'%s'\s+'(__TLS_\w+_B64__)'\s*\|\s*base64\s+-d", cfn_txt)
if c_default:
    c_case["Route53"] = c_default.group(1)  # DnsProvider AllowedValues make the *) branch == Route53
for prov, (var, ph, frag) in CFN_EXPECT.items():
    if c_case.get(prov) != ph:
        errors.append(f"cloudformation/aws-vm: DnsProvider '{prov}' case selects {c_case.get(prov)}, expected {ph}")
    if c_var2file.get(var) != frag:
        errors.append(f"cloudformation/aws-vm: build.sh embeds '{c_var2file.get(var)}' for {var}, expected {frag}")
if re.search(r"printf\s+['\"]tls\s*\{", cfn_txt):
    errors.append("cloudformation/aws-vm: re-inlines a printf 'tls{...}' -- must embed+decode the fragment")
# ALL __*_B64__ placeholders (not just the TLS set above) must match build.sh's substitution
# tuple exactly -- a template placeholder build.sh does not substitute ships as literal garbage.
all_build_ph = set(re.findall(r'\("(__\w+__)",\s*"\w+"\)', build_txt))
all_tmpl_ph = set(re.findall(r"__[A-Z][A-Z0-9_]*_B64__", cfn_txt))
if all_build_ph != all_tmpl_ph:
    errors.append(f"cloudformation/aws-vm: build.sh substitution set {sorted(all_build_ph)} != template "
                  f"placeholder set {sorted(all_tmpl_ph)}")
if not any("cloudformation" in e for e in errors):
    notes.append("CFN embeds+selects the correct fragment per provider (route53 = instance-role variant)")


# --- 4. DigitalOcean: validation set == env map keys == fragments; Caddyfile imports the fragment -
do_main, do_vars, do_ci = read(DO_MAIN), read(DO_VARS), read(DO_CLOUDINIT)
allowed = set(re.findall(r'"(\w+)"', re.search(r"contains\(\[([^\]]+)\]", do_vars).group(1))) if re.search(r"contains\(\[([^\]]+)\]", do_vars) else set()
env_map = dict(re.findall(r'(\w+)\s*=\s*"(\w+)"', re.search(r"dns_env_var\s*=\s*lookup\(\{([^}]+)\}", do_main).group(1))) if re.search(r"dns_env_var\s*=\s*lookup\(\{([^}]+)\}", do_main) else {}
if allowed != set(env_map):
    errors.append(f"terraform/digitalocean: dns_provider validation {sorted(allowed)} != dns_env_var map "
                  f"keys {sorted(env_map)} -- an allowed provider with no env mapping breaks issuance")
for prov, envk in env_map.items():
    frag = f"{prov}.caddy"
    if frag not in CATALOG:
        errors.append(f"terraform/digitalocean: provider '{prov}' has no caddy-tls/{frag}")
    elif envk not in CATALOG[frag][1]:
        errors.append(f"terraform/digitalocean: dns_env_var maps '{prov}' -> {envk}, but {frag} reads "
                      f"{sorted(CATALOG[frag][1])}")
if "import /etc/caddy/tls.caddy" not in do_ci:
    errors.append("terraform/digitalocean/cloud-init.yaml: Caddyfile must 'import /etc/caddy/tls.caddy' "
                  "(the fragment is written but never consumed otherwise)")
if "tls_fragment" not in do_ci or "caddy-tls/" not in do_main:
    errors.append("terraform/digitalocean: no longer loads the caddy-tls fragment via templatefile")
if re.search(r"\n\s*dns\s+[a-z0-9$]", do_ci):
    errors.append("terraform/digitalocean/cloud-init.yaml: re-inlines a 'dns <provider>' block")
if not any("digitalocean" in e for e in errors):
    notes.append(f"DigitalOcean validation/env-map/fragments agree ({sorted(allowed)}); Caddyfile imports it")


# --- 5. compose: tls.caddy active block IS cloudflare.caddy; env parity + coverage ---------------
canonical_cf = read(f"{TLS_DIR}/cloudflare.caddy").strip()
for path in (WP_TLS, WPE_TLS):
    active = "\n".join(l for l in read(path).splitlines() if not l.lstrip().startswith("#")).strip()
    if active != canonical_cf:
        errors.append(f"{os.path.relpath(path, REPO)}: active tls block is not identical to caddy-tls/cloudflare.caddy")


def caddy_env_keys(path):
    import yaml
    doc = yaml.safe_load(read(path))
    env = (doc.get("services", {}).get("caddy", {}) or {}).get("environment", {})
    if isinstance(env, dict):
        keys = set(env)
    elif isinstance(env, list):
        keys = {i.split("=", 1)[0].split(":", 1)[0].strip() for i in env}
    else:
        keys = set()
    return keys


all_keys = {k for _, ks in CATALOG.values() for k in ks} | {"GOOGLE_APPLICATION_CREDENTIALS"}
wp_keys, wpe_keys = caddy_env_keys(WP) & all_keys, caddy_env_keys(WPE) & all_keys
if wp_keys != wpe_keys:
    errors.append("compose Caddy DNS-01 env block DIVERGES between the two compose files: "
                  f"only-wp={sorted(wp_keys - wpe_keys)} only-wpe={sorted(wpe_keys - wp_keys)}")
else:
    notes.append(f"compose env provider keys match across both files ({len(wp_keys)} keys)")
# every env key the compose/bicep/CFN fragments need must be in the compose block (GODADDY is DO-only).
need = {k for f, (_, ks) in CATALOG.items() if f != "godaddy.caddy" for k in ks}
missing = sorted(need - wpe_keys)
if missing:
    errors.append(f"compose caddy env block is missing fragment env keys: {missing}")


# --- report ----------------------------------------------------------------------------------
for n in notes:
    print(f"OK: {n}")
if errors:
    print()
    for e in errors:
        print(f"::error::{e}")
    print(f"\nCaddy DNS-01 config DRIFT: {len(errors)} issue(s). caddy-tls/ is the single source; every "
          "target must select the fragment whose plugin + credential env keys match its provider "
          "(see the CATALOG / *_EXPECT tables in this script).")
    sys.exit(1)
print("OK: one canonical tls source; every target selects the correct fragment; tuning policy intact.")
sys.exit(0)
