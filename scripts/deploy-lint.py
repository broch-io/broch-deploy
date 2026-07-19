#!/usr/bin/env python3
"""Deploy-surface lint: structural invariants that keep redeploys into a dirty
environment safe. Every rule here encodes a property whose loss once produced (or
would produce) a real "second deploy fails / silently loses state" incident class:

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

Usage: deploy-lint.py [--root DIR]     (default: the repo containing this script)
Output: one line per violation, "RULE path:line message"; exit 1 on any violation.
Stdlib only.
"""

import argparse
import os
import re
import subprocess
import sys

violations = []


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
    rel = "cloudformation/aws-vm/template.yaml"
    lines = read_lines(root, rel)
    if lines is not None:
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
    rule_pin(root)
    rule_zone(root)

    if violations:
        for v in violations:
            print(v)
        print(f"deploy-lint: {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print("deploy-lint: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
