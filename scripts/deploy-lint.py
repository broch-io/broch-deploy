#!/usr/bin/env python3
"""Deploy-surface lint: structural invariants that keep redeploys into a dirty
environment safe and customer-facing templates clean. Almost every rule encodes a
property whose loss once produced (or would produce) a real "deploy fails / silently
loses state" incident class:

  R1a  CloudFormation Secrets Manager names are salted with the stack incarnation
       UUID (AWS::StackId), so a delete+redeploy or rollback-retry never collides
       with the 30-day soft-deleted ghost of a previous incarnation.
  R1b  The azure-vm template keeps the region-salted Key Vault name derivation and
       the explicit soft-delete recover pre-pass (kv-recover.bicep), so recreating
       a resource group of the same name+region recovers its vault ghosts.
  R3a  The azure-vm data disk is unconditional: attached in every database mode
       (it persists the TLS cert store, not just the Local database), never gated
       back behind databaseMode and never assembled via a conditional
       storageProfile union() whose non-Local branch would present a
       zero-data-disks desired state.
  R3b  Every docker-compose stack maps Caddy's /data to a NAMED volume, so issued
       certificates survive container recreation instead of re-requesting against
       Let's Encrypt's duplicate-certificate rate limit.
  R4   The master key is required everywhere: no template gives the master-key
       parameter a default, so a redeploy can never silently proceed with a key
       that does not match the database it reuses.
  EMAIL The Let's Encrypt email is required everywhere: the azure-vm acmeEmail has
       no default and a @minLength, the aws-vm AcmeEmail has no Default and an
       AllowedPattern that rejects '', and every compose file whose Caddyfile uses
       it passes it as ${CADDY_ACME_EMAIL:?...}. Caddy refuses an empty email, so a
       blank value would leave the appliance with no TLS and no auto-DNS records.
  META The aws-vm templates carry no tooling telemetry markers (AWSToolsMetrics):
       authoring tools can insert them, and they would ship in every customer template.
  PIN  Broch image references pin the exact version in scripts/BROCH_VERSION and
       are never :latest (a floating tag would roll a recreated box across an
       irreversible EF-migration boundary). Delegates the per-site sync check to
       bump-broch-version.py --check (the pin catalog's single source of truth)
       and additionally sweeps for off-catalog image references. broch-caddy is
       deliberately :latest (schema-free sidecar) and exempt.
  ZONE No hard-coded availability zone anywhere in the deploy surface: a pinned
       zone deploys fine for us and then fails (capacity/unsupported zone) or
       silently mis-places a data volume for a customer account/region that
       cannot satisfy it. Zones must come from a parameter/variable or a dynamic
       lookup, never a literal.
  AUTH Every deploy target (compose, VM, container) hands broch the full
       AUTHENTICATION__* key set from its deployment inputs (every provider's
       fields, not just the ones the smoke tests happen to fill): a dropped
       TENANTID / INSTANCE / AUTHORITY line boots fine for Auth0 and fails broch's
       required-field check at boot for every Entra or OIDC customer. Both Bicep
       templates also route the audience and provider through checkedAuthAudience
       and checkedAuthProvider, fail() guards that refuse settings broch would
       refuse at startup at preflight, before any resource.
  DNSRG The azure-vm template hands Caddy the Azure DNS zone's resource group
       through checkedDnsZoneResourceGroup, a fail() guard that refuses a blank one
       at preflight when either Azure DNS provider is selected: Caddy can't issue
       the certificate without it, so the deployment would succeed with a VM that
       never serves TLS.
  WIRE The Terraform targets give broch nothing outside the setting local the configuration
       contract check (config-contract.py) renders except the master key, connection string
       and client secret references, each wired from the generator that check sizes: a
       stray setting, or a master key from another generator, would be judged by nothing.
  AMI  The aws-vm UbuntuAmi default pins a Canonical release serial, never the
       stable/current alias: CloudFormation re-resolves SSM parameters on every
       stack update, so the alias turned any update after a new Ubuntu image into
       an instance replacement (a rollback in Local mode, whose data volume the new
       instance cannot attach).

Usage: deploy-lint.py [--root DIR]     (default: the repo containing this script)
Output: one line per violation, "RULE path:line message"; exit 1 on any violation.
Stdlib only.
"""

import argparse
import json
import os
import re
import subprocess
import sys

violations = []


def aws_templates(root: str):
    """Canonical source plus every published generated variant."""
    base = "cloudformation/aws-vm"
    manifest = os.path.join(root, base, "published_variants.yaml")
    try:
        with open(manifest, encoding="utf-8") as fh:
            entries = json.load(fh)
    except (OSError, ValueError) as exc:
        violate("LINT", manifest, 1, f"invalid variant manifest: {exc}")
        return [f"{base}/template.yaml"]
    return [f"{base}/template.yaml"] + [
        f"{base}/dist/template-{e['auth'].lower()}-{e['db'].lower()}-{e['dns'].lower()}.yaml"
        for e in entries
    ]


def violate(rule: str, path: str, line: int, message: str) -> None:
    """Record one violation in the canonical 'RULE path:line message' shape."""
    violations.append(f"{rule} {path}:{line} {message}")


def read_lines(root: str, rel: str):
    """Read root/rel as a line list; a missing expected file is itself a violation."""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        violate("LINT", rel, 1, "expected file is missing")
        return None


# The CANONICAL salt expression — !Select index 2 of the StackId split (the incarnation
# UUID). A looser check (any AWS::StackId mention) would pass !Select [1, ...], which
# resolves to the stack NAME segment and defeats the uniqueness guarantee entirely.
STACK_ID_SALT = re.compile(r"!Select\s*\[\s*2\s*,\s*!Split\s*\[.*AWS::StackId")


def rule_r1a(root: str) -> None:
    """Every AWS::SecretsManager::Secret with an explicit Name must salt it with
    the AWS::StackId incarnation UUID. (A secret with NO Name gets a
    CloudFormation-generated unique name — also ghost-safe, so only explicit
    names are checked.)"""
    for dirpath, _dirs, files in os.walk(os.path.join(root, "cloudformation")):
        for fn in files:
            if not fn.endswith((".yaml", ".yml")):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)
            lines = read_lines(root, rel)
            if lines is None:
                continue
            for i, line in enumerate(lines):
                if "Type: AWS::SecretsManager::Secret" not in line:
                    continue
                indent = len(line) - len(line.lstrip())
                # The resource block: from the Type line to the next line at an
                # indent shallower than the Type line (the next resource / section).
                start = i
                end = len(lines)
                for j in range(i + 1, len(lines)):
                    stripped = lines[j].strip()
                    if (stripped and not stripped.startswith("#")
                            and len(lines[j]) - len(lines[j].lstrip()) < indent):
                        end = j
                        break
                block = lines[start:end]
                has_name = any(re.match(r"\s*Name:", b) for b in block)
                if has_name and not any(STACK_ID_SALT.search(b) for b in block):
                    violate("R1a", rel, start + 1,
                            "SecretsManager secret has an explicit Name without the "
                            "AWS::StackId incarnation salt — a delete+redeploy or "
                            "rollback-retry will collide with the 30-day soft-deleted ghost")


def rule_r1b(root: str) -> None:
    """Azure vault ghosts: region-salted vault names + the kv-recover pre-pass stay."""
    rel = "bicep/azure-vm/main.bicep"
    lines = read_lines(root, rel)
    if lines is None:
        return
    text = "\n".join(lines)
    if "uniqueString(resourceGroup().id, vmName, location)" not in text:
        violate("R1b", rel, 1,
                "Key Vault name derivation lost its region salt "
                "(uniqueString(resourceGroup().id, vmName, location)) — a cross-region "
                "recreate would collide with the old region's vault ghost")
    if "kv-recover.bicep" not in text:
        violate("R1b", rel, 1,
                "the kv-recover.bicep soft-delete recover pre-pass is no longer referenced — "
                "same-name/same-region recreation will fail on soft-deleted vaults")


def rule_r3a(root: str) -> None:
    """azure-vm data disk is unconditional (every mode), attach + mounts ungated."""
    rel = "bicep/azure-vm/main.bicep"
    lines = read_lines(root, rel)
    if lines is not None:
        disk_decl = [i for i, l in enumerate(lines) if "'Microsoft.Compute/disks@" in l]
        if not disk_decl:
            violate("R3a", rel, 1, "no managed data-disk resource found — the persistent "
                                   "cert-store/database disk is gone")
        for i in disk_decl:
            if re.search(r"=\s*if\s*\(", lines[i]):
                violate("R3a", rel, i + 1,
                        "the data disk resource is conditional again — it must exist in "
                        "EVERY database mode (it persists the TLS cert store, not just "
                        "the Local database)")
        for i, line in enumerate(lines):
            if "storageProfile" in line and "union(" in line:
                violate("R3a", rel, i + 1,
                        "storageProfile is assembled with union() again — the non-Local "
                        "branch would declare a dataDisks-less desired state and a "
                        "mode-flip redeploy would detach the data disk")
        if not any("dataDisks:" in l for l in lines):
            violate("R3a", rel, 1, "no dataDisks attachment found — the data disk is "
                                   "created but never attached")
    rel = "bicep/azure-vm/cloud-init.yaml"
    lines = read_lines(root, rel)
    if lines is not None:
        for i, line in enumerate(lines):
            if re.search(r'"__LOCAL_DB__"\s*=\s*"true"', line):
                violate("R3a", rel, i + 1,
                        "disk/mount handling is gated on __LOCAL_DB__ equality again — "
                        "the data disk mount and its fail-closed guards must run in "
                        "every database mode (only the != connstring gate is legitimate)")


def rule_r3b(root: str) -> None:
    """Every compose stack maps Caddy's /data to a named volume (cert persistence)."""
    base = os.path.join(root, "docker-compose")
    if not os.path.isdir(base):
        violate("LINT", "docker-compose", 1, "expected directory is missing")
        return
    named = re.compile(r"^\s*-\s*[A-Za-z0-9_]+:/data(\s|$|:ro|:rw)")
    bind = re.compile(r"^\s*-\s*[./~].*:/data(\s|$)")
    for entry in sorted(os.listdir(base)):
        rel = os.path.join("docker-compose", entry, "docker-compose.yml")
        if not os.path.isfile(os.path.join(root, rel)):
            continue
        lines = read_lines(root, rel)
        if lines is None:
            continue
        if not any(named.match(l) for l in lines):
            violate("R3b", rel, 1,
                    "Caddy's /data is not mapped to a named volume — issued certificates "
                    "die with the container and recreation re-requests against Let's "
                    "Encrypt's duplicate-certificate rate limit")
        for i, l in enumerate(lines):
            if bind.match(l):
                violate("R3b", rel, i + 1,
                        "/data is bind-mounted instead of using a named volume")


def rule_r4(root: str) -> None:
    """Master-key parameters are required — no default in any marketplace template."""
    # bicep: a master-key param line must not carry a default.
    for rel in ("bicep/azure-vm/main.bicep", "bicep/azure-container-apps/mainTemplate.bicep"):
        lines = read_lines(root, rel)
        if lines is None:
            continue
        found = False
        for i, line in enumerate(lines):
            m = re.match(r"\s*param\s+(brochMasterKey|masterKey)\s+string(.*)", line)
            if m:
                found = True
                if "=" in m.group(2):
                    violate("R4", rel, i + 1,
                            f"master-key param {m.group(1)} has a default — it must be "
                            "required so a redeploy can never silently run with a key "
                            "that does not match the reused database")
        if not found:
            violate("R4", rel, 1, "no master-key param found (brochMasterKey/masterKey)")
    # cloudformation: the BrochMasterKey parameter block must not carry Default.
    for rel in aws_templates(root):
        lines = read_lines(root, rel)
        if lines is None:
            continue
        for i, line in enumerate(lines):
            if re.match(r"  BrochMasterKey:\s*$", line):
                # Scan the whole parameter block — bounded by the next entry at the
                # same 2-space indent, not a fixed window (Description text in this
                # repo regularly runs longer than a dozen lines).
                for j in range(i + 1, len(lines)):
                    if re.match(r"  \S", lines[j]):  # next parameter block
                        break
                    if re.match(r"\s+Default:", lines[j]):
                        violate("R4", rel, j + 1,
                                "BrochMasterKey has a Default — it must be required")
                break
        else:
            violate("R4", rel, 1, "no BrochMasterKey parameter found")


def rule_email(root: str) -> None:
    """The Let's Encrypt email is required on every target that can hand it to Caddy."""
    why = ("a blank email crash-loops Caddy (Auto) or stops the shared compose (every mode) "
           "-- no TLS, no auto-DNS records, an unreachable appliance")
    # bicep: acmeEmail has no default and a @minLength(>=1) decorator above it.
    rel = "bicep/azure-vm/main.bicep"
    lines = read_lines(root, rel)
    if lines is not None:
        for i, line in enumerate(lines):
            m = re.match(r"\s*param\s+acmeEmail\s+string(.*)", line)
            if not m:
                continue
            if "=" in m.group(1):
                violate("EMAIL", rel, i + 1, f"acmeEmail has a default -- it must be required; {why}")
            decorators = []
            for j in range(i - 1, -1, -1):
                if not lines[j].lstrip().startswith("@"):
                    break
                decorators.append(lines[j])
            if not any(re.match(r"\s*@minLength\(\s*[1-9]\d*\s*\)", d) for d in decorators):
                violate("EMAIL", rel, i + 1, f"acmeEmail lost its @minLength -- '' would pass ARM validation; {why}")
            break
        else:
            violate("EMAIL", rel, 1, "no acmeEmail param found")
    # cloudformation: the AcmeEmail block has no Default, and its AllowedPattern rejects ''.
    for rel in aws_templates(root):
        lines = read_lines(root, rel)
        if lines is None:
            continue
        for i, line in enumerate(lines):
            if not re.match(r"  AcmeEmail:\s*$", line):
                continue
            pattern = None
            for j in range(i + 1, len(lines)):
                if re.match(r"  \S", lines[j]):  # next parameter block
                    break
                if re.match(r"\s+Default:", lines[j]):
                    violate("EMAIL", rel, j + 1, f"AcmeEmail has a Default -- it must be required; {why}")
                p = re.match(r"\s+AllowedPattern:\s*(['\"])(.*)\1\s*$", lines[j])
                if p:
                    pattern = p.group(2)
            if pattern is None:
                violate("EMAIL", rel, i + 1, "AcmeEmail has no quoted AllowedPattern -- '' would be accepted")
            else:
                try:
                    if re.fullmatch(pattern, ""):
                        violate("EMAIL", rel, i + 1, f"AcmeEmail's AllowedPattern accepts '' -- {why}")
                except re.error as exc:  # CFN patterns are Java regex; keep this one portable
                    violate("EMAIL", rel, i + 1, f"AcmeEmail's AllowedPattern is not checkable ({exc})")
            break
        else:
            violate("EMAIL", rel, 1, "no AcmeEmail parameter found")
    # compose: every stack whose Caddyfile reads the email must refuse to start while it is blank
    # -- keyed on the Caddyfile, so deleting the compose line (or a list-form entry) is caught too.
    base = os.path.join(root, "docker-compose")
    for entry in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        caddyfile = os.path.join(root, "docker-compose", entry, "Caddyfile")
        rel = os.path.join("docker-compose", entry, "docker-compose.yml")
        if not os.path.isfile(caddyfile) or not os.path.isfile(os.path.join(root, rel)):
            continue
        with open(caddyfile, encoding="utf-8") as fh:
            if not any(re.match(r"\s*email\s+\{env\.CADDY_ACME_EMAIL\}", l) for l in fh):
                continue
        lines = read_lines(root, rel) or []
        if not any("${CADDY_ACME_EMAIL:?" in l for l in lines):
            violate("EMAIL", rel, 1, f"its Caddyfile uses CADDY_ACME_EMAIL but compose does not "
                                     f"${{...:?}}-require it -- {why}")


def rule_meta(root: str) -> None:
    """No authoring-tool telemetry marker in any aws-vm template (canonical + variants)."""
    for rel in aws_templates(root):
        lines = read_lines(root, rel)
        for i, line in enumerate(lines or []):
            if "AWSToolsMetrics" in line:
                violate("META", rel, i + 1, "tooling telemetry marker in a customer template -- remove it")


AUTH_KEYS = ("PROVIDER", "CLIENTID", "ADMINROLES", "DOMAIN", "TENANTID", "INSTANCE", "AUTHORITY", "AUDIENCE")
# Each key's deployment input, snake_case; each target spells it in its own convention.
AUTH_INPUT = {"PROVIDER": "provider", "CLIENTID": "client_id", "ADMINROLES": "admin_roles", "DOMAIN": "domain",
              "TENANTID": "tenant_id", "INSTANCE": "instance", "AUTHORITY": "authority", "AUDIENCE": "audience",
              "CLIENTSECRET": "client_secret"}


def camel(key: str) -> str:
    return "".join(part.title() for part in AUTH_INPUT[key].split("_"))


def uncommented_lines(root: str, rel: str):
    """The file's lines with comments blanked: `#` everywhere, plus `//` and `/* */` in
    Terraform and Bicep (only there -- a shell glob like `lists/*` in cloud-init is not a
    comment opener). Blanked, not dropped, so an index is still the file's line number - 1."""
    lines = read_lines(root, rel)
    if lines is None:
        return None
    if rel.endswith((".tf", ".bicep")):
        text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), "\n".join(lines), flags=re.S)
        lines = ["" if line.lstrip().startswith("//") else line for line in text.split("\n")]
    return ["" if line.lstrip().startswith("#") else line for line in lines]


def rule_auth(root: str) -> None:
    """Every target wires every AUTHENTICATION__ key to broch from that key's own input."""
    why = "broch refuses to boot, or ignores what the customer entered, for the providers that need it"

    def live_lines(rel):
        return uncommented_lines(root, rel)

    def line_of(live, hint):
        """1-based line of the first live line mentioning the key, else 1 (the wiring is absent)."""
        return next((i + 1 for i, line in enumerate(live) if re.search(hint, line)), 1)

    def require(rel, keys, source, live=None, hint=lambda k: rf"AUTHENTICATION__{k}\b"):
        """source(key) is a regex that one line must match."""
        live = live_lines(rel) if live is None else live
        for key in keys if live is not None else ():
            if not any(re.search(source(key), line) for line in live):
                violate("AUTH", rel, line_of(live, hint(key)),
                        f"AUTHENTICATION__{key} is not wired from its own input -- {why}")

    def require_sequence(rel, patterns, message, hint=None):
        """Consecutive code lines (comments and blank lines skipped) matching the patterns in order."""
        live = live_lines(rel)
        if live is None:
            return
        code = [(i, line) for i, line in enumerate(live) if line.strip()]
        n = len(patterns)
        if not any(all(re.search(p, code[s + j][1]) for j, p in enumerate(patterns)) for s in range(len(code) - n + 1)):
            violate("AUTH", rel, line_of(live, hint or patterns[0]), message)

    def require_block(rel, keys, name, source):
        """Multi-line env entries: a line matching name(key) with source(key) on the next
        non-blank line (comments are blanked, so a comment between the two doesn't break it)."""
        live = live_lines(rel)
        code = [line for line in live if line.strip()] if live is not None else []
        for key in keys if live is not None else ():
            if not any(re.search(name(key), a) and re.search(source(key), b) for a, b in zip(code, code[1:])):
                violate("AUTH", rel, line_of(live, name(key)),
                        f"AUTHENTICATION__{key} is not wired from its own input -- {why}")

    # compose: the broch service maps each key from the same-named environment/.env entry. Only
    # the broch service counts -- the same line under caddy would never reach broch.
    base = os.path.join(root, "docker-compose")
    for entry in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        rel = os.path.join("docker-compose", entry, "docker-compose.yml")
        if not os.path.isfile(os.path.join(root, rel)):
            continue
        live = live_lines(rel)
        if live is None:
            continue
        services = next((i for i, line in enumerate(live) if re.fullmatch(r"services:\s*(?:#.*)?", line)), None)
        start = next((i for i in range(services + 1, len(live)) if re.fullmatch(r"  broch:\s*(?:#.*)?", live[i])),
                     None) if services is not None else None
        if start is None or any(re.match(r"\S", live[i]) for i in range(services + 1, start)):
            violate("AUTH", rel, 1, "no `broch:` service found under `services:`")
            continue
        end = next((i for i in range(start + 1, len(live)) if re.match(r"(?:  )?\S", live[i])), len(live))
        broch = ["" if not start <= i < end else line for i, line in enumerate(live)]
        require(rel, (*AUTH_KEYS, "CLIENTSECRET"),
                lambda k: rf"^\s+AUTHENTICATION__{k}:\s*\$\{{AUTHENTICATION__{k}:-\}}\s*$", live=broch)
    # VM appliances write the keys into /opt/broch/.env: a Terraform templatefile var, a Bicep
    # __TOKEN__ replace, a CloudFormation ${Param}. A literal, or another key's input, would boot
    # but ignore what the customer entered. The client secret is hydrated from the platform
    # secret store at boot on azure-vm and aws-vm, so it is not in those templates as a value.
    do_var = lambda k: "admin_roles" if k == "ADMINROLES" else f"auth_{AUTH_INPUT[k]}"
    # DigitalOcean single-quotes them, so docker compose takes the value literally (unquoted, it
    # would trim it and interpolate any $VAR in it).
    require("terraform/digitalocean/cloud-init.yaml", (*AUTH_KEYS, "CLIENTSECRET"),
            lambda k: rf"^\s+AUTHENTICATION__{k}='\$\{{{do_var(k)}\}}'\s*$")
    require("bicep/azure-vm/cloud-init.yaml", AUTH_KEYS,
            lambda k: rf"^\s+AUTHENTICATION__{k}='__AUTH_{AUTH_INPUT[k].upper()}__'\s*$")
    # ...and main.bicep fills each token from the key's own parameter. The audience and provider go
    # through checkedAuthAudience / checkedAuthProvider, the fail() guards that refuse settings
    # Broch would refuse at startup, at preflight.
    vm_input = lambda k: {"AUDIENCE": "checkedAuthAudience", "PROVIDER": "checkedAuthProvider"}.get(k, f"auth{camel(k)}")
    require("bicep/azure-vm/main.bicep", AUTH_KEYS,
            lambda k: rf"^\s+\['__AUTH_{AUTH_INPUT[k].upper()}__',\s*{vm_input(k)}\]",
            hint=lambda k: rf"__AUTH_{AUTH_INPUT[k].upper()}__")
    for rel in aws_templates(root):
        require(rel, AUTH_KEYS, lambda k: rf"^\s+AUTHENTICATION__{k}='\$\{{Auth{camel(k)}\}}'\s*$")
        require(rel, ("CLIENTSECRET",),
                lambda k: rf"^\s*put AUTHENTICATION__{k} broch-auth-client-secret$")
    # Terraform targets keep the plain settings in one local (local.broch_environment on the
    # container targets, local.user_data on DigitalOcean): what the configuration contract check
    # (scripts/config-contract.py) renders. These pin the resource to use exactly that local, whole
    # and unfiltered, so what the check judges is what Broch gets. The client secret is a separate
    # secret reference on the container targets.
    rendered = ("is not set from the local the configuration contract check renders, so the check would "
                "judge settings broch never gets")
    ecs = "terraform/aws-ecs/compute.tf"
    require(ecs, AUTH_KEYS, lambda k: rf"^\s+AUTHENTICATION__{k}\s*=\s*var\.auth_{AUTH_INPUT[k]}\s*$")
    require_sequence(ecs, [r"^\s+environment\s*=\s*\[for\s+(\w+),\s*(\w+)\s+in\s+local\.broch_environment\s*:"
                           r"\s*\{\s*name\s*=\s*\1,\s*value\s*=\s*\2\s*\}\s*\]\s*$"],
                     f"the task's environment {rendered}", hint=r"^\s+environment\s*=")
    require_block(ecs, ("CLIENTSECRET",), lambda k: rf'^\s+name\s*=\s*"AUTHENTICATION__{k}"',
                  lambda k: r"^\s+valueFrom\s*=\s*aws_secretsmanager_secret\.auth_client_secret\.arn\s*$")
    aca_tf = "terraform/azure-container-apps/containerapp.tf"
    require(aca_tf, AUTH_KEYS, lambda k: rf"^\s+AUTHENTICATION__{k}\s*=\s*var\.auth_{AUTH_INPUT[k]}\s*$")
    require_sequence(aca_tf, [r'^\s+dynamic\s+"env"\s*\{\s*$', r"^\s+for_each\s*=\s*local\.broch_environment\s*$",
                              r"^\s+content\s*\{\s*$", r"^\s+name\s*=\s*env\.key\s*$",
                              r"^\s+value\s*=\s*env\.value\s*$", r"^\s+\}\s*$", r"^\s+\}\s*$"],
                     f"the container's env {rendered}")
    do_tf = "terraform/digitalocean/main.tf"
    require_sequence(do_tf, [r'^\s+user_data\s*=\s*templatefile\("\$\{path\.module\}/cloud-init\.yaml",\s*\{\s*$'],
                     "local.user_data must be the cloud-init.yaml templatefile")
    require_sequence(do_tf, [r"^\s+user_data\s*=\s*local\.user_data\s*$"], f"the droplet's user_data {rendered}",
                     hint=r"^\s+user_data\s*=\s*(?!templatefile)")
    require_block(aca_tf, ("CLIENTSECRET",), lambda k: rf'^\s+name\s*=\s*"AUTHENTICATION__{k}"',
                  lambda k: r'^\s+secret_name\s*=\s*"auth-client-secret"\s*$')
    # Bicep values may be expressions (INSTANCE defaults to the cloud's login endpoint), so the
    # value line must reference the key's own parameter rather than equal it -- as an expression,
    # not inside a '...' string literal (no quote may precede it on the line). The audience and
    # provider go through the fail() guards, as on azure-vm.
    aca_bicep = "bicep/azure-container-apps/mainTemplate.bicep"
    bicep_input = lambda k: {"AUDIENCE": "checkedAuthAudience", "PROVIDER": "checkedAuthProvider",
                             "ADMINROLES": "adminRoles"}.get(k, f"auth{camel(k)}")
    require_block(aca_bicep, AUTH_KEYS, lambda k: rf"^\s+name:\s*'AUTHENTICATION__{k}'",
                  lambda k: rf"^\s+value:[^'\n]*\b{bicep_input(k)}\b")
    require_block(aca_bicep, ("CLIENTSECRET",), lambda k: rf"^\s+name:\s*'AUTHENTICATION__{k}'",
                  lambda k: r"^\s+secretRef:\s*'auth-client-secret'\s*$")
    # The guard itself: a params-only variable whose Auth0 branch fail()s. ARM evaluates it at
    # preflight, so an Auth0 deployment without an audience never creates a resource.
    for rel in ("bicep/azure-vm/main.bicep", aca_bicep):
        live = live_lines(rel)
        if live is None:
            continue
        guard = next((i for i, line in enumerate(live) if line.startswith("var checkedAuthAudience =")), None)
        # The declaration runs to its else line (`: authAudience`); inline // comments dropped.
        end = next((i for i in range(guard, len(live)) if re.match(r"\s*:", live[i])), None) \
            if guard is not None else None
        body = [re.sub(r"\s*//.*", "", line) for line in live[guard:end + 1]] if end is not None else []
        # No negation is allowed: a `!` could invert the audience test (e.g.
        # `!(empty(trim(authAudience)))`). ACA's configure-in-app gate is the `authConfigured` flag.
        cond = " ".join(body[:-1])
        if not (body and "!" not in cond and re.search(r"==\s*'auth0'", cond)
                and re.search(r"\bempty\(trim\(authAudience\)\)", cond)
                and re.search(r"\?\s*fail\(", cond) and re.fullmatch(r"\s*:\s*authAudience\s*", body[-1])):
            violate("AUTH", rel, guard + 1 if guard is not None else 1,
                    "checkedAuthAudience must fail() for Auth0 with a blank authAudience and otherwise yield "
                    "authAudience -- else broch refuses to boot only after the resources exist")


def rule_dnsrg(root: str) -> None:
    """azure-vm: the Azure DNS zone's resource group reaches cloud-init only through its preflight guard."""
    rel = "bicep/azure-vm/main.bicep"
    live = uncommented_lines(root, rel)
    if live is None:
        return
    why = "a blank resource group deploys a VM whose Caddy can't issue the certificate"
    # cloud-init reads the resource group through the guard, which keeps the guard wired in.
    if not any(re.search(r"^\s+\['__AZURE_DNS_RESOURCE_GROUP__',\s*checkedDnsZoneResourceGroup\]", line)
               for line in live):
        token = next((i + 1 for i, line in enumerate(live) if "__AZURE_DNS_RESOURCE_GROUP__" in line), 1)
        violate("DNSRG", rel, token,
                f"__AZURE_DNS_RESOURCE_GROUP__ is not filled from checkedDnsZoneResourceGroup -- the preflight "
                f"guard is bypassed and {why}")
    # The guard: a params-only variable that fail()s when an Azure DNS provider is selected with a blank
    # resource group. ARM evaluates it at preflight, before any resource exists. The declaration runs to
    # its else line (`: dnsZoneResourceGroup`); inline // comments dropped. No negation is allowed: a `!`
    # could invert the blank test.
    guard = next((i for i, line in enumerate(live) if line.startswith("var checkedDnsZoneResourceGroup =")), None)
    end = next((i for i in range(guard, len(live)) if re.match(r"\s*:", live[i])), None) \
        if guard is not None else None
    body = [re.sub(r"\s*//.*", "", line) for line in live[guard:end + 1]] if end is not None else []
    cond = " ".join(body[:-1])
    if not (body and "!" not in cond and re.search(r"\busesAzureDns\b", cond)
            and re.search(r"\bempty\(trim\(dnsZoneResourceGroup\)\)", cond)
            and re.search(r"\?\s*fail\(", cond) and re.fullmatch(r"\s*:\s*dnsZoneResourceGroup\s*", body[-1])):
        violate("DNSRG", rel, guard + 1 if guard is not None else 1,
                "checkedDnsZoneResourceGroup must fail() when usesAzureDns and dnsZoneResourceGroup is blank, "
                f"and otherwise yield dnsZoneResourceGroup -- else {why}")
    # ...and usesAzureDns must select exactly the Auto-mode Azure DNS providers. Pinned whole (whitespace
    # aside): a flipped comparison or a negation would otherwise slip past and silently skip the guard.
    expected = ("var usesAzureDns = certMode == 'Auto' && "
                "(dnsProvider == 'AzureDns' || dnsProvider == 'AzureDnsServicePrincipal')")
    uses = next((i for i, line in enumerate(live) if line.startswith("var usesAzureDns =")), None)
    if uses is None or " ".join(re.sub(r"\s*//.*", "", live[uses]).split()) != expected:
        violate("DNSRG", rel, uses + 1 if uses is not None else 1,
                f"usesAzureDns must read `{expected[len('var usesAzureDns = '):]}` -- else the "
                f"checkedDnsZoneResourceGroup guard skips an Azure DNS provider, and {why}")


BROCH_IMAGE = re.compile(r"ghcr\.io/broch-io/broch:([A-Za-z0-9._-]+)")


def rule_pin(root: str) -> None:
    """Exact version pins: bump-broch-version --check + an off-catalog :latest sweep."""
    # The per-site sync check is owned by bump-broch-version.py (its SITES catalog
    # fails loudly if a pin moves or stops matching) — run it, don't duplicate it.
    result = subprocess.run(
        [sys.executable, os.path.join(root, "scripts", "bump-broch-version.py"), "--check"],
        capture_output=True, text=True, env={**os.environ, "REPO_ROOT": root},
    )
    if result.returncode != 0:
        out = (result.stdout + result.stderr).strip().replace("\n", " | ")
        violate("PIN", "scripts/BROCH_VERSION", 1, f"bump-broch-version.py --check failed: {out}")

    # Sweep for image references the catalog does not know about: any literal
    # ghcr.io/broch-io/broch:<tag> in the deploy surface must be the pinned version
    # (and never latest). broch-caddy is not matched (deliberately :latest).
    try:
        with open(os.path.join(root, "scripts", "BROCH_VERSION"), encoding="utf-8") as f:
            pinned = f.read().strip()
    except FileNotFoundError:
        violate("PIN", "scripts/BROCH_VERSION", 1, "missing — it is the pin's single source of truth")
        return
    for top in ("bicep", "cloudformation", "terraform", "docker-compose"):
        for dirpath, _dirs, files in os.walk(os.path.join(root, top)):
            for fn in files:
                if not fn.endswith((".bicep", ".yaml", ".yml", ".tf", ".json")):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                lines = read_lines(root, rel)
                if lines is None:
                    continue
                for i, line in enumerate(lines):
                    for m in BROCH_IMAGE.finditer(line):
                        tag = m.group(1)
                        if tag == "latest":
                            violate("PIN", rel, i + 1,
                                    "broch image floats on :latest — a recreate would "
                                    "silently roll the box across an EF-migration boundary")
                        elif tag != pinned:
                            violate("PIN", rel, i + 1,
                                    f"broch image pinned to {tag}, but scripts/BROCH_VERSION "
                                    f"is {pinned} — bump with scripts/bump-broch-version.py")


# A literal AWS availability zone, e.g. us-east-1a / eu-central-1b (an AZ is a
# region name plus a trailing letter). Quoted or bare; may be terminated by a
# comma or a closing bracket (inline lists) as well as whitespace/end-of-line.
AWS_AZ_LITERAL = re.compile(r"""["']?[a-z]{2}(?:-[a-z]+)+-\d[a-f]["']?\s*(?:$|,|\])""")
# Property/attribute shapes that ASSIGN an availability zone.
CFN_AZ_KEY = re.compile(r"^\s*AvailabilityZone\w*\s*:")
TF_AZ_KEY = re.compile(r"^\s*availability_zone\w*\s*=")
# bicep: a zones property with a literal array pins Azure zone indices ('1'/'2'/'3').
BICEP_ZONES_LITERAL = re.compile(r"^\s*zones\s*:\s*\[\s*'")


def rule_zone(root: str) -> None:
    """No hard-coded availability zone in any deploy target — zones must come from
    a parameter/variable or a dynamic lookup (!Ref / !GetAZs / data source), never
    a literal, so a template never assumes a zone a customer account/region can't
    place resources in."""
    for top, exts in (("cloudformation", (".yaml", ".yml")),
                      ("terraform", (".tf",)),
                      ("bicep", (".bicep",))):
        for dirpath, _dirs, files in os.walk(os.path.join(root, top)):
            for fn in files:
                if not fn.endswith(exts):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                lines = read_lines(root, rel)
                if lines is None:
                    continue
                hardcoded = ("availability zone is hard-coded — take it from a "
                             "parameter/variable or a dynamic lookup so the template "
                             "never assumes a zone the target account/region can't place")
                for i, line in enumerate(lines):
                    code = line.split("#", 1)[0].split("//", 1)[0]
                    if TF_AZ_KEY.match(code) and AWS_AZ_LITERAL.search(code):
                        violate("ZONE", rel, i + 1, hardcoded)
                    elif CFN_AZ_KEY.match(code):
                        value = code.split(":", 1)[1].strip()
                        if AWS_AZ_LITERAL.search(value):
                            violate("ZONE", rel, i + 1, hardcoded)
                        elif value in ("", "[", "|", ">", ">-", "|-"):
                            # The value continues on the following, deeper-indented
                            # lines (YAML block list / block scalar / open inline
                            # list) — scan that whole block for AZ literals.
                            indent = len(line) - len(line.lstrip())
                            for j in range(i + 1, len(lines)):
                                nxt = lines[j].split("#", 1)[0]
                                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                                    break
                                if AWS_AZ_LITERAL.search(nxt):
                                    violate("ZONE", rel, j + 1, hardcoded)
                    elif BICEP_ZONES_LITERAL.match(code):
                        violate("ZONE", rel, i + 1,
                                "Azure zones are pinned to literal indices — leave the "
                                "resource regional or parameterize the zone")


def rule_ami(root: str) -> None:
    """aws-vm UbuntuAmi defaults to a pinned Canonical serial, never the stable/current alias."""
    for rel in aws_templates(root):
        lines = read_lines(root, rel)
        if lines is None:
            continue
        in_block = False
        for i, line in enumerate(lines):
            if line.startswith("  UbuntuAmi:"):
                in_block = True
                continue
            if in_block and re.match(r"  \S", line):
                break
            if in_block and line.strip().startswith("Default:") and "/current/" in line:
                violate("AMI", rel, i + 1,
                        "UbuntuAmi defaults to Canonical's stable/current alias — CloudFormation "
                        "re-resolves it on every update, so any update after a new Ubuntu image "
                        "replaces the instance (and rolls back in Local mode); pin a release serial")


def rule_wire(root: str) -> None:
    """Terraform targets: the only settings broch gets outside the local the configuration contract
    check renders are the secret references, each wired from the generator the check judges."""
    def code(rel):
        """(line number, line) for the file's non-blank, non-comment lines."""
        lines = read_lines(root, rel)
        return None if lines is None else [
            (i + 1, line) for i, line in enumerate(lines)
            if line.strip() and not line.lstrip().startswith(("#", "//"))]

    def sequence(rel, patterns, message):
        lines = code(rel)
        if lines is None:
            return
        n = len(patterns)
        if not any(all(re.search(p, lines[s + j][1]) for j, p in enumerate(patterns))
                   for s in range(len(lines) - n + 1)):
            violate("WIRE", rel, 1, message)

    outside = "a setting outside local.broch_environment is invisible to the configuration contract check"
    # azure-container-apps: each static env block is one of these secret references.
    aca = "terraform/azure-container-apps/containerapp.tf"
    aca_secrets = {"BROCH_MASTER_KEY": "master-key", "ConnectionStrings__BrochConnection": "postgres-connection-string",
                   "AUTHENTICATION__CLIENTSECRET": "auth-client-secret"}
    lines = code(aca) or []
    dynamic = [number for number, line in lines if re.search(r'\bdynamic\s+"env"', line)]
    if len(dynamic) != 1:
        violate("WIRE", aca, dynamic[1] if dynamic else 1, f'expected one dynamic "env" block (local.broch_environment): {outside}')
    for k, (number, line) in enumerate(lines):
        if re.fullmatch(r"\s+env\s*\{\s*", line):
            name = re.fullmatch(r'\s+name\s*=\s*"(\w+)"\s*', lines[k + 1][1]) if k + 1 < len(lines) else None
            secret = aca_secrets.get(name.group(1)) if name else None
            if secret is None or k + 2 >= len(lines) or \
                    not re.fullmatch(rf'\s+secret_name\s*=\s*"{secret}"\s*', lines[k + 2][1]):
                violate("WIRE", aca, number, f"env block is not one of the secret references {sorted(aca_secrets)}: {outside}")
    for name, secret in aca_secrets.items():
        sequence(aca, [r"^\s+env\s*\{\s*$", rf'^\s+name\s*=\s*"{name}"\s*$', rf'^\s+secret_name\s*=\s*"{secret}"\s*$'],
                 f"{name} is not set from the {secret} secret")
    for secret, resource in (("master-key", "master_key"), ("postgres-connection-string", "postgres_connection_string")):
        sequence(aca, [r"^\s+secret\s*\{\s*$", rf'^\s+name\s*=\s*"{secret}"\s*$',
                       rf"^\s+key_vault_secret_id\s*=\s*azurerm_key_vault_secret\.{resource}\.id\s*$"],
                 f"the {secret} secret is not azurerm_key_vault_secret.{resource}")
    sequence("terraform/azure-container-apps/main.tf",
             [r'^resource\s+"azurerm_key_vault_secret"\s+"master_key"\s*\{', r'^\s+name\s*=\s*"master-key"\s*$',
              r"^\s+value\s*=\s*random_password\.master_key\.result\s*$"],
             "the master-key secret is not random_password.master_key (the generator the contract check sizes)")
    # aws-ecs: one environment list (the rendered local); each secret is one of these references.
    ecs = "terraform/aws-ecs/compute.tf"
    ecs_secrets = {"BROCH_MASTER_KEY": "master_key", "ConnectionStrings__BrochConnection": "connection_string",
                   "AUTHENTICATION__CLIENTSECRET": "auth_client_secret"}
    lines = code(ecs) or []
    environments = [number for number, line in lines if re.search(r"\benvironment\s*=", line)]
    if len(environments) != 1:
        violate("WIRE", ecs, environments[1] if environments else 1, f"expected one task environment list: {outside}")
    for number, line in lines:
        if re.search(r"\benvironmentFiles\b", line):
            violate("WIRE", ecs, number, f"environmentFiles: {outside}")
    for k, (number, line) in enumerate(lines):
        if not re.search(r"\bvalueFrom\b", line):
            continue
        # The secret's name: on the same line (a one-line object) or the line before (the usual layout).
        # Anything else is flagged rather than assumed.
        own = re.search(r'\bname\s*=\s*"(\w+)"', line)
        prev = re.fullmatch(r'\s+name\s*=\s*"(\w+)"\s*', lines[k - 1][1]) if k else None
        name = (own or prev).group(1) if own or prev else None
        resource = ecs_secrets.get(name)
        if resource is None or not re.search(rf"\bvalueFrom\s*=\s*aws_secretsmanager_secret\.{resource}\.arn\b", line):
            violate("WIRE", ecs, number, f"secret {name or '(unnamed)'} is not one of the references {sorted(ecs_secrets)}: {outside}")
    for name, resource in ecs_secrets.items():
        sequence(ecs, [rf'^\s+name\s*=\s*"{name}"\s*$', rf"^\s+valueFrom\s*=\s*aws_secretsmanager_secret\.{resource}\.arn\s*$"],
                 f"{name} is not set from aws_secretsmanager_secret.{resource}")
    sequence("terraform/aws-ecs/database.tf",
             [r'^resource\s+"aws_secretsmanager_secret_version"\s+"master_key"\s*\{',
              r"^\s+secret_id\s*=\s*aws_secretsmanager_secret\.master_key\.id\s*$",
              r"^\s+secret_string\s*=\s*random_password\.master_key\.result\s*$"],
             "the master key secret is not random_password.master_key (the generator the contract check sizes)")
    # digitalocean: the .env placeholder is replaced by the key the runcmd generates (the contract
    # check sizes it from that openssl command).
    sequence("terraform/digitalocean/cloud-init.yaml", [r"""^\s+MASTER_KEY=\$\(openssl rand -base64 \d+ \| tr -d '\\n'\)\s*$"""],
             "the master key is not generated by the openssl line the contract check sizes")
    sequence("terraform/digitalocean/cloud-init.yaml",
             [r"""^\s+sed -i "s\|\^BROCH_MASTER_KEY=__GENERATED_AT_RUNTIME__\|BROCH_MASTER_KEY=\$\$\{MASTER_KEY\}\|" /opt/broch/\.env\s*$"""],
             "the .env BROCH_MASTER_KEY placeholder is not replaced by the generated key")


def main() -> int:
    """Run every rule against --root and report violations (exit 1 on any)."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..")))
    args = parser.parse_args()
    root = os.path.abspath(args.root)

    rule_r1a(root)
    rule_r1b(root)
    rule_r3a(root)
    rule_r3b(root)
    rule_r4(root)
    rule_email(root)
    rule_meta(root)
    rule_auth(root)
    rule_dnsrg(root)
    rule_wire(root)
    rule_pin(root)
    rule_zone(root)
    rule_ami(root)

    if violations:
        for v in violations:
            print(v)
        print(f"deploy-lint: {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print("deploy-lint: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
