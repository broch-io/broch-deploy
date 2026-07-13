#!/usr/bin/env python3
"""Single source of truth for the pinned broch image version across every deploy template.

The templates deliberately pin a CONCRETE stable version (not :latest) so a customer
`docker compose pull` / redeploy never silently rolls the box across an irreversible
EF-migration boundary. The cost is that the pin lives in many hand-synced sites; this
script owns them all, driven by the `scripts/BROCH_VERSION` file (kept beside this
script so the pair promotes to the public repo atomically).

  scripts/bump-broch-version.py 1.30.0   -> rewrite every pin site + BROCH_VERSION to 1.30.0
  scripts/bump-broch-version.py --check  -> verify every site matches BROCH_VERSION (CI guard);
                                            exit 0 = in sync, 1 = drift (each drifting site listed)

SITES is the canonical catalog. Every pattern is anchored to the exact pin syntax of its file
and must match EXACTLY once -- a refactor that moves/renames a pin makes this script fail
loudly (in both modes) instead of silently skipping the site. Prose mentions of versions
(e.g. "1.29.0+ is required for dnsAutoRecords=Auto" feature floors) are intentionally NOT
matched: they are historical/floor references, not pins.

NOT covered (different repo): the broch monorepo's marketplace createUiDefinition.json
`brochVersion` default -- bump it with the marketplace package rebuild.
"""
import os
import re
import sys

REPO = os.environ.get("REPO_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VERSION_FILE = f"{REPO}/scripts/BROCH_VERSION"

SEMVER = r"\d+\.\d+\.\d+"

# (relative path, anchored pattern with ONE capture group around the version)
SITES = [
    # docker-compose defaults (the VM appliances embed these files verbatim, so they inherit)
    ("docker-compose/with-postgres/docker-compose.yml",
     rf"\$\{{BROCH_VERSION:-({SEMVER})\}}"),
    ("docker-compose/with-postgres-external/docker-compose.yml",
     rf"\$\{{BROCH_VERSION:-({SEMVER})\}}"),
    ("docker-compose/with-postgres-byo-cert/docker-compose.yml",
     rf"\$\{{BROCH_VERSION:-({SEMVER})\}}"),
    # .env.example documentation of the same default
    ("docker-compose/with-postgres/.env.example",
     rf"(?m)^# BROCH_VERSION=({SEMVER})$"),
    ("docker-compose/with-postgres-external/.env.example",
     rf"(?m)^# BROCH_VERSION=({SEMVER})$"),
    ("docker-compose/with-postgres-byo-cert/.env.example",
     rf"(?m)^# BROCH_VERSION=({SEMVER})$"),
    # bicep
    ("bicep/azure-vm/main.bicep",
     rf"(?m)^param brochVersion string = '({SEMVER})'$"),
    ("bicep/azure-container-apps/mainTemplate.bicep",
     rf"(?m)^param containerImage string = 'ghcr\.io/broch-io/broch:({SEMVER})'$"),
    # terraform variable defaults + their tfvars.example documentation
    ("terraform/digitalocean/variables.tf",
     rf"(?m)^  default     = \"({SEMVER})\"$"),
    ("terraform/digitalocean/terraform.tfvars.example",
     rf"(?m)^# image_tag\s+= \"({SEMVER})\""),
    ("terraform/aws-ecs/variables.tf",
     rf"(?m)^  default     = \"ghcr\.io/broch-io/broch:({SEMVER})\"$"),
    ("terraform/aws-ecs/terraform.tfvars.example",
     rf"(?m)^# broch_image\s+= \"ghcr\.io/broch-io/broch:({SEMVER})\""),
    ("terraform/azure-container-apps/variables.tf",
     rf"(?m)^  default     = \"ghcr\.io/broch-io/broch:({SEMVER})\"$"),
    ("terraform/azure-container-apps/terraform.tfvars.example",
     rf"(?m)^# broch_image\s+= \"ghcr\.io/broch-io/broch:({SEMVER})\""),
    # cloudformation parameter default (anchored to the BrochVersion block so other
    # String parameters with semver-looking defaults can never be caught)
    ("cloudformation/aws-vm/template.yaml",
     rf"(?m)^  BrochVersion:\n    Type: String\n    Default: \"({SEMVER})\""),
]


def read_canonical() -> str:
    try:
        with open(VERSION_FILE) as f:
            version = f.read().strip()
    except FileNotFoundError:
        sys.exit(f"FAIL: {VERSION_FILE} missing — it is the single source of truth for the pin")
    if not re.fullmatch(SEMVER, version):
        sys.exit(f"FAIL: BROCH_VERSION contains {version!r}, not a plain semver (X.Y.Z)")
    return version


def scan(apply_version: str | None):
    """Walk SITES; return list of (path, found_version). apply_version rewrites in place."""
    results, errors = [], []
    for rel, pattern in SITES:
        path = f"{REPO}/{rel}"
        with open(path) as f:
            text = f.read()
        matches = list(re.finditer(pattern, text))
        if len(matches) != 1:
            errors.append(f"  {rel}: pattern matched {len(matches)}x (expected exactly 1) — pin moved/renamed?")
            continue
        m = matches[0]
        results.append((rel, m.group(1)))
        if apply_version is not None and m.group(1) != apply_version:
            start, end = m.span(1)
            with open(path, "w") as f:
                f.write(text[:start] + apply_version + text[end:])
    if errors:
        sys.exit("FAIL: pin catalog out of date with the templates:\n" + "\n".join(errors))
    return results


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    if sys.argv[1] == "--check":
        canonical = read_canonical()
        drift = [(rel, v) for rel, v in scan(None) if v != canonical]
        if drift:
            print(f"FAIL: BROCH_VERSION is {canonical} but these sites drift:")
            for rel, v in drift:
                print(f"  {rel}: {v}")
            print("Run scripts/bump-broch-version.py <version> — never edit a pin by hand.")
            return 1
        print(f"OK: all {len(SITES)} pin sites match BROCH_VERSION={canonical}")
        return 0

    new = sys.argv[1].lstrip("v")
    if not re.fullmatch(SEMVER, new):
        sys.exit(f"FAIL: {sys.argv[1]!r} is not a plain semver (X.Y.Z)")
    changed = [rel for rel, v in scan(new) if v != new]
    with open(VERSION_FILE, "w") as f:
        f.write(new + "\n")
    print(f"BROCH_VERSION -> {new}; rewrote {len(changed)}/{len(SITES)} sites"
          + (":" if changed else " (all already current)"))
    for rel in changed:
        print(f"  {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
