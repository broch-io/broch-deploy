#!/usr/bin/env bash
# scripts/test-terraform.sh — end-to-end test of a Terraform deployment example.
#
# Stands up the module against your real cloud account, waits for broch to
# respond on /healthz, then tears everything down.
#
# Run this manually before tagging a release, or whenever you bump the broch
# image / a provider version. NOT for CI — this repo is public and we don't
# want workflow logs leaking account state.
#
# Usage:
#   scripts/test-terraform.sh aws-ecs            # tests terraform/aws-ecs/
#   scripts/test-terraform.sh azure-container-apps
#   scripts/test-terraform.sh aws-ecs --keep     # apply, verify, but skip destroy
#
# Prerequisites:
#   - terraform CLI on PATH (>=1.6)
#   - Cloud credentials configured (aws configure / az login)
#   - terraform.tfvars filled in for the target module — copy from
#     terraform.tfvars.example. The script doesn't fill these for you because
#     they include your license key + GitHub PAT.
#
# Cost: a single apply→destroy cycle is a few dollars (mostly NAT gateway
# hourly + RDS provisioning minimum). The script always attempts destroy on
# exit (including on failure) to keep that bound — but `terraform destroy`
# can fail, so check your cloud console after if anything errors.

set -euo pipefail

# ─── Arg parsing ─────────────────────────────────────────────────────────────

readonly MODULE="${1:-}"
readonly KEEP_FLAG="${2:-}"

if [[ -z "$MODULE" ]]; then
    cat <<EOF >&2
Usage: $0 <module> [--keep]

Available modules:
  aws-ecs
  azure-container-apps

Examples:
  $0 aws-ecs
  $0 azure-container-apps --keep
EOF
    exit 64  # EX_USAGE
fi

readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly MODULE_DIR="$REPO_ROOT/terraform/$MODULE"

if [[ ! -d "$MODULE_DIR" ]]; then
    echo "ERROR: module dir not found: $MODULE_DIR" >&2
    exit 1
fi

if [[ ! -f "$MODULE_DIR/terraform.tfvars" ]]; then
    echo "ERROR: $MODULE_DIR/terraform.tfvars not found." >&2
    echo "Copy terraform.tfvars.example to terraform.tfvars and fill it in." >&2
    exit 1
fi

# ─── Cleanup trap ────────────────────────────────────────────────────────────
# Always attempt destroy on exit (success or failure), unless --keep was given.
# This is the discipline that keeps a forgotten apply from running up a bill.

cleanup() {
    local exit_code=$?
    if [[ "$KEEP_FLAG" == "--keep" ]]; then
        echo
        echo "═══ --keep specified — leaving infrastructure in place ═══"
        echo "Run 'terraform -chdir=$MODULE_DIR destroy -auto-approve' when done."
        exit "$exit_code"
    fi
    echo
    echo "═══ Cleanup: terraform destroy ═══"
    if ! terraform -chdir="$MODULE_DIR" destroy -auto-approve; then
        echo "ERROR: destroy failed. Check your cloud console for orphaned resources." >&2
        exit_code=1
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# ─── Apply ───────────────────────────────────────────────────────────────────

echo "═══ terraform init ═══"
terraform -chdir="$MODULE_DIR" init -upgrade

echo
echo "═══ terraform apply ═══"
terraform -chdir="$MODULE_DIR" apply -auto-approve

# ─── Verify ──────────────────────────────────────────────────────────────────

echo
echo "═══ Verifying broch is reachable ═══"

BROCH_URL=$(terraform -chdir="$MODULE_DIR" output -raw broch_url)
echo "URL: $BROCH_URL"

# Give broch a moment after first apply — RDS/Postgres provisioning is the
# long pole on AWS, ACA cold-start is the long pole on Azure. Both should be
# under 5 minutes after apply returns.
echo "Waiting for /healthz to return 200 (up to 5 min)..."

for attempt in {1..30}; do
    if curl -fsS --max-time 10 "${BROCH_URL}/healthz" >/dev/null 2>&1; then
        echo "✓ broch responded healthy on attempt $attempt"
        exit 0
    fi
    sleep 10
done

echo "ERROR: broch never responded healthy at ${BROCH_URL}/healthz" >&2
echo "Check terraform output, cloud-side logs, and DNS propagation." >&2
exit 1
