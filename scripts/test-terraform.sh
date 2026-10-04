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
#   scripts/test-terraform.sh digitalocean
#   scripts/test-terraform.sh aws-ecs --keep     # apply, verify, but skip destroy
#   scripts/test-terraform.sh aws-ecs --destroy  # only tear down (after --keep)
#
# The teardown lifts the modules' database guards for this throwaway stack only: aws-ecs gets
# -var rds_deletion_protection=false, and azure-container-apps and digitalocean (whose database
# server / data volume has prevent_destroy) get a temporary override file, removed right after.
# So the script refuses a module directory whose state already holds resources: never point it
# at a checkout that manages a real deployment.
#
# Prerequisites:
#   - terraform CLI on PATH (>=1.6)
#   - Cloud credentials configured (aws configure / az login / a DigitalOcean API token in
#     do_token)
#   - terraform.tfvars filled in for the target module — copy from
#     terraform.tfvars.example. The script doesn't fill these for you because
#     they include secrets (e.g. your IdP client secret).
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
Usage: $0 <module> [--keep | --destroy]

Available modules:
  aws-ecs
  azure-container-apps
  digitalocean

Examples:
  $0 aws-ecs
  $0 azure-container-apps --keep
  $0 azure-container-apps --destroy
EOF
    exit 64  # EX_USAGE
fi

if [[ -n "$KEEP_FLAG" && "$KEEP_FLAG" != "--keep" && "$KEEP_FLAG" != "--destroy" ]]; then
    echo "ERROR: unknown option: $KEEP_FLAG (expected --keep or --destroy)" >&2
    exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly REPO_ROOT
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

# aws-ecs turns RDS deletion protection on by default, which would make the cleanup destroy fail;
# this throwaway stack turns it off. A -var, not TF_VAR_: terraform.tfvars would override that.
EXTRA_VARS=()
if [[ "$MODULE" == "aws-ecs" ]]; then
    EXTRA_VARS=(-var rds_deletion_protection=false)
fi

# azure-container-apps's database server and digitalocean's data volume carry prevent_destroy,
# which can't be switched by a variable. An override file (merged into the resource's lifecycle
# block) lifts it, written just before each destroy and removed right after.
readonly GUARD_OVERRIDE="$MODULE_DIR/zz_test_teardown_override.tf"
case "$MODULE" in
    azure-container-apps) GUARDED_RESOURCE='"azurerm_postgresql_flexible_server" "broch"' ;;
    digitalocean)         GUARDED_RESOURCE='"digitalocean_volume" "broch_data"' ;;
    *)                    GUARDED_RESOURCE='' ;;
esac
# One left behind by an interrupted teardown would silently disable the guard: remove it.
rm -f "$GUARD_OVERRIDE"

destroy_once() {
    if [[ -n "$GUARDED_RESOURCE" ]]; then
        printf '%s\n' "# Written by scripts/test-terraform.sh for its teardown; removed right after." \
            "resource $GUARDED_RESOURCE {" '  lifecycle {' '    prevent_destroy = false' '  }' '}' \
            > "$GUARD_OVERRIDE"
    fi
    local status=0
    terraform -chdir="$MODULE_DIR" destroy -auto-approve ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"} || status=$?
    rm -f "$GUARD_OVERRIDE"
    return "$status"
}

destroy_stack() {
    # Never leave the override behind on Ctrl-C or a kill.
    # Clear the EXIT trap too, so an interrupt can never re-enter cleanup and restart the destroy.
    trap 'trap - EXIT; rm -f "$GUARD_OVERRIDE"; echo "ERROR: teardown interrupted; check your cloud console." >&2; exit 130' INT
    trap 'trap - EXIT; rm -f "$GUARD_OVERRIDE"; echo "ERROR: teardown interrupted; check your cloud console." >&2; exit 143' TERM
    # Azure can take a few minutes to release subnets and the like after deleting what uses them,
    # and the provider sometimes fails a delete that has already happened: retry before giving up.
    local attempt
    for attempt in 1 2 3; do
        if destroy_once; then
            return 0
        fi
        if [[ "$attempt" -lt 3 ]]; then
            echo "destroy failed (attempt $attempt of 3); retrying in 60s ..." >&2
            sleep 60
        fi
    done
    return 1
}

cleanup() {
    local exit_code=$?
    if [[ "$KEEP_FLAG" == "--keep" ]]; then
        echo
        echo "═══ --keep specified — leaving infrastructure in place ═══"
        echo "Run '$0 $MODULE --destroy' when done."
        exit "$exit_code"
    fi
    echo
    echo "═══ Cleanup: terraform destroy ═══"
    if ! destroy_stack; then
        echo "ERROR: destroy failed. Check your cloud console for orphaned resources." >&2
        exit_code=1
    fi
    exit "$exit_code"
}
trap cleanup EXIT

if [[ "$KEEP_FLAG" == "--destroy" ]]; then
    # Initialise first, so a fresh checkout can reach the state. A backend that needs -backend-config
    # values must be initialised by hand before running this.
    echo "═══ terraform init ═══"
    if ! terraform -chdir="$MODULE_DIR" init -input=false; then
        trap - EXIT
        echo "ERROR: terraform init failed; nothing was destroyed." >&2
        exit 1
    fi
    exit 0  # the trap tears the stack down
fi

# ─── Apply ───────────────────────────────────────────────────────────────────

echo "═══ terraform init ═══"
terraform -chdir="$MODULE_DIR" init -upgrade

# This script destroys what it applies, guards lifted. Refuse to run against a module directory
# that already manages a stack (a real deployment, or a --keep run not yet torn down).
# Ask whichever backend is configured (local or remote), not just the local state file: a checkout
# whose backend holds a real deployment's state has no local terraform.tfstate.
EXISTING_STATE=""
STATE_OUTPUT=""
if STATE_OUTPUT="$(terraform -chdir="$MODULE_DIR" state list 2>&1)"; then
    EXISTING_STATE="$STATE_OUTPUT"
elif [[ "$STATE_OUTPUT" != *"No state file was found"* ]]; then
    trap - EXIT
    echo "ERROR: could not read the Terraform state for $MODULE_DIR; not applying." >&2
    printf '%s\n' "$STATE_OUTPUT" >&2
    exit 1
fi
if [[ -n "$EXISTING_STATE" ]]; then
    trap - EXIT
    echo "ERROR: $MODULE_DIR already has resources in its Terraform state." >&2
    echo "This script only tests throwaway stacks. Use a separate checkout, or '$0 $MODULE --destroy'" >&2
    echo "if this is a stack an earlier --keep run left behind." >&2
    exit 1
fi

echo
echo "═══ terraform apply ═══"
terraform -chdir="$MODULE_DIR" apply -auto-approve ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}

# ─── Verify ──────────────────────────────────────────────────────────────────

echo
echo "═══ Verifying broch is reachable ═══"

BROCH_URL=$(terraform -chdir="$MODULE_DIR" output -raw broch_url)
echo "URL: $BROCH_URL"

# Give broch a moment after first apply — RDS/Postgres provisioning is the
# long pole on AWS, ACA cold-start is the long pole on Azure, and a droplet
# installs Docker and issues its certificate on first boot. Allow 10 minutes.
echo "Waiting for /healthz to return 200 (up to 10 min)..."

for attempt in {1..60}; do
    if curl -fsS --max-time 10 "${BROCH_URL}/healthz" >/dev/null 2>&1; then
        echo "✓ broch responded healthy on attempt $attempt"
        exit 0
    fi
    sleep 10
done

echo "ERROR: broch never responded healthy at ${BROCH_URL}/healthz" >&2
echo "Check terraform output, cloud-side logs, and DNS propagation." >&2
exit 1
