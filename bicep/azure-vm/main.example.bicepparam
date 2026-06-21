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

// Master key. With databaseMode='Managed' (a brand-new DB) you may leave this unset — the
// template generates one and stores it in the Key Vault it creates (secret 'broch-master-key').
// With databaseMode='Existing' (this example's default) it is REQUIRED — supply that database's
// key (a fresh key can't decrypt data it already holds). Prefer passing via --parameters.
param brochMasterKey = '<master-key>' // openssl rand -base64 48 for a fresh DB; reuse the existing DB's key

// --- Database: Existing (bring your own) or Managed (provision a private Flex Server) ---
param databaseMode = 'Existing'
// Existing:
param databaseConnectionString = 'Host=mydb.postgres.database.azure.com;Database=brochdb;Username=<user>;Password=<pw>;SSL Mode=Require' // prefer --parameters
// Managed (set databaseMode = 'Managed' above, then):
// param postgresAdminPassword = '<strong-password>'  // prefer --parameters
// param postgresSkuName       = 'Standard_B1ms'      // B1ms | B2s | D2ds_v5 | D4ds_v5

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
// param brochVersion = 'latest'      // pin to the running version before any prod cutover
