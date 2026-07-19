// Soft-delete RECOVERY pre-pass for the deployment's Key Vaults, in a MODULE so the same vault can
// be PUT twice in one deployment: this bare createMode:'recover' PUT first (nested deployments run
// before the parent's vault resources via dependsOn), then main.bicep's normal vault PUTs apply the
// full desired state — the new VM identity's access policy, enabledForTemplateDeployment, flags.
//
// WHY: deleting a resource group only SOFT-DELETES its
// vaults, and recreating the group under the same name IN THE SAME REGION re-derives the same
// deterministic vault names (names are region-salted, so a different region derives fresh names and
// never collides). Azure then auto-recovers a soft-deleted vault on a plain PUT **only when the request
// matches the vault's state at deletion** — accessPolicies and property flags included. The
// break-glass vault always matches (RBAC mode, constant properties) and recovers invisibly; the
// app vault NEVER matches, because its recorded state names the PREVIOUS deployment's VM identity
// and every attempt mints a fresh one — so it fails with "A vault with the same name already
// exists in deleted state" on every retry. createMode:'recover' bypasses the state-match (all
// other properties are ignored on a recover PUT), which is the one ARM-expressible way past it.
//
// Each vault is recovered ONLY when its exact name was found in the subscription's soft-deleted set
// (recoverApp / recoverBg, decided by the caller intersecting softDeletedVaultNames with the exact
// computed names): a recover PUT FAILS when no vault of that name exists in ANY state, so this must
// never run unconditionally — not on first deploys, and not against a ghost whose name belongs to an
// older template version. Over a LIVE vault of the same name it is a harmless no-op update, so a
// Redeploy retry that re-carries the names (the portal prefills them from the picked history entry)
// cannot break anything. Recovered vaults come back with the previous deployment's secrets — under the
// required-secrets model the supplied values simply overwrite them, so recovery changes nothing about
// what the customer enters.
// Copyright (c) 2026 Broch, LLC. All rights reserved.

param location string
param kvName string
param bgKvName string
param recoverApp bool
param recoverBg bool

// Conditional: recover the app vault only when its exact name was found soft-deleted (recoverApp). A
// recover PUT FAILS when no vault of that name exists in ANY state, so recovering unconditionally would
// hard-fail whenever the supplied ghost belongs to an older template version whose name no longer
// matches kvName — the caller intersects on the exact name and passes recoverApp=false in that case.
resource appVaultRecover 'Microsoft.KeyVault/vaults@2023-07-01' = if (recoverApp) {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    createMode: 'recover'
  }
}

// The break-glass vault usually auto-recovers on its own (state-match holds), but recover it
// explicitly too so a cross-version property change can never strand it. Conditional: SSH-key
// deployments (usePassword=false) never created one, so there is no ghost to recover. Corollary:
// keep the SAME auth mode (password vs SSH key) as the deleted deployment when recovering — a
// deleted SSH-key deployment left no break-glass ghost, so recreating it in password mode with
// this flag makes this PUT fail loudly (nothing to recover). Mode switches need a fresh group
// name or a purge instead.
resource bgVaultRecover 'Microsoft.KeyVault/vaults@2023-07-01' = if (recoverBg) {
  name: bgKvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    createMode: 'recover'
  }
}
