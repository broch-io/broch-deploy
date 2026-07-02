// Example parameters for main.bicep. Copy to a local `main.bicepparam` and fill in.
// DO NOT commit real secrets — pass cloudflareApiToken / authClientSecret on the
// CLI (--parameters) or via Key Vault references instead, and keep your real
// .bicepparam out of git.
using 'main.bicep'

// --- Networking / access ---
// SSH is closed by default (no inbound 22) and the VM is provisioned with a generated
// break-glass password — manage via `az vm run-command` / Serial Console. No SSH key
// required. Uncomment ONLY if you specifically want key-based SSH (then also set a CIDR):
// param adminSshPublicKey = 'ssh-ed25519 AAAA...your-public-key... you@example'
// param sshAllowedCidr    = '203.0.113.0/24'
// Optional: AAD object ID to grant Key Vault Secrets User (read the generated secrets):
// param adminObjectId = '<your-user-or-group-object-id>'

// Master key — REQUIRED (>=32 chars). The at-rest encryption root; generate with
// `openssl rand -base64 48` and supply the SAME value on every (re)deploy. For an existing DB,
// use that database's key (a different key can't decrypt its data). Prefer --parameters over committing.
param brochMasterKey = '<run: openssl rand -base64 48>' // placeholder is <32 chars on purpose — @minLength rejects it until you replace it

// --- Database: Existing (bring your own) | Managed (provision a private Flex Server) | Local (on the VM) ---
param databaseMode = 'Existing'
// Existing:
param databaseConnectionString = 'Host=mydb.postgres.database.azure.com;Database=brochdb;Username=<user>;Password=<pw>;SSL Mode=Require' // prefer --parameters
// Managed (set databaseMode = 'Managed' above, then):
// param postgresAdminPassword = '<strong-password>'  // prefer --parameters
// param postgresSkuName       = 'Standard_B1ms'      // B1ms | B2s | D2ds_v5 | D4ds_v5
// Local (set databaseMode = 'Local'): Postgres runs ON the VM on a small dedicated data disk —
// zero prerequisites, but YOU manage backups (no automated backups / PITR). Optional size override:
// param dataDiskSizeGb = 4   // GiB; Broch's DB is tiny — size up only for large audit-log history
// Optional hardening: by default the Local Postgres password is DERIVED (computable by anyone with
// Reader on the subscription). Set an explicit one for any deployment where the VM identity could be
// compromised, and re-supply the SAME value on every redeploy (Postgres keeps its first password):
// param localDbAdminPassword = '<strong-password>'  // prefer --parameters
// NOTE: always redeploy a Local-mode VM with --mode Incremental (the default). A `--mode Complete`
// deploy of this resource group with databaseMode != 'Local' would DELETE the <vmName>-data disk (it
// is absent from the template for non-Local modes), destroying the database.

// --- Domain + TLS (bring your own domain) ---
param wildcardHostname = 'tunnels.example.com'
param certMode = 'Auto' // Auto (Let's Encrypt) | Byo (your own cert)
param acmeEmail = 'ops@example.com'
// DNS-01 provider (certMode=Auto). Pick one and set its credentials:
param dnsProvider = 'Cloudflare'
param cloudflareApiToken = '<cloudflare-zone-dns-token>' // Zone:Read + DNS:Edit; prefer --parameters
// Azure DNS — managed identity (template auto-grants DNS Zone Contributor; needs Owner/UAA):
// param dnsProvider          = 'AzureDns'
// param dnsZoneResourceGroup = '<dns-zone-resource-group>'
// Azure DNS — service principal (Contributor is enough; pre-grant the SP on the zone):
// param dnsProvider       = 'AzureDnsServicePrincipal'
// param dnsZoneResourceGroup = '<dns-zone-resource-group>'
// param azureTenantId     = '<tenant-id>'
// param azureClientId     = '<app-client-id>'
// param azureClientSecret = '<app-client-secret>'      // prefer --parameters
// AWS Route 53:
// param dnsProvider        = 'Route53'
// param awsAccessKeyId     = '<aws-access-key-id>'
// param awsSecretAccessKey = '<aws-secret-access-key>' // prefer --parameters
// Google Cloud DNS:
// param dnsProvider        = 'GoogleCloudDns'
// param gcpProject         = '<gcp-project-id>'
// param gcpCredentialsJson = '<base64 service-account JSON>' // prefer --parameters
// DigitalOcean:
// param dnsProvider = 'DigitalOcean'
// param doAuthToken = '<do-api-token>'                 // prefer --parameters
// Byo cert (set certMode = 'Byo'):
// param tlsCertificate    = '<base64 PEM fullchain>'   // prefer --parameters
// param tlsCertificateKey = '<base64 PEM private key>' // prefer --parameters

// --- Identity provider (boot floor — set what your provider needs) ---
param authProvider = 'Auth0'
param authClientId = '<client-id>'
param authClientSecret = '<client-secret>' // prefer --parameters over committing
param authAdminRoles = 'broch_admin'
param authDomain = 'your-tenant.auth0.com'
// AzureAd/Entra: set authTenantId + authInstance instead of authDomain.
// Generic OIDC: set authAuthority.

// Telemetry, logging, and the license are configured IN-APP (Admin UI) after first
// sign-in — not here. The central server URL defaults to https://api.broch.io in code.

// --- Optional ---
// param vmSize = 'Standard_B2ps_v2'  // ARM64; check family quota/availability in your region
// param brochVersion = '1.26.0'      // defaults to a concrete pinned version; set a newer tag to upgrade
// Private pre-release/beta image — server/username default to GHCR, so set only the token:
// param brochImage = 'ghcr.io/broch-io/broch-beta'
// param registryPassword = '<registry-token>'  // prefer --parameters
