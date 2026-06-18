// Example parameters for main.bicep. Copy to a local `main.bicepparam` and fill in.
// DO NOT commit real secrets — pass cloudflareApiToken / authClientSecret on the
// CLI (--parameters) or via Key Vault references instead, and keep your real
// .bicepparam out of git.
using 'main.bicep'

// --- Networking / access ---
param adminSshPublicKey = 'ssh-ed25519 AAAA...replace-with-your-public-key... you@example'
// SSH is closed by default (no inbound 22; manage via `az vm run-command` / Serial
// Console). Uncomment + set a CIDR ONLY for break-glass SSH from your admin network:
// param sshAllowedCidr = '203.0.113.0/24'

param brochMasterKey = '<master-key>' // openssl rand -base64 48; prefer --parameters; reuse the DB's existing key if taking one over

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
// Auto + Cloudflare:
param dnsProvider = 'Cloudflare'
param cloudflareApiToken = '<cloudflare-zone-dns-token>' // Zone:Read + DNS:Edit; prefer --parameters
// Auto + Azure DNS (no secret — grant the VM identity "DNS Zone Contributor" post-deploy):
// param dnsProvider          = 'AzureDns'
// param dnsZoneResourceGroup = '<dns-zone-resource-group>'
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
// param authScopes = ''   // extra OAuth scopes, only if your IdP requires them

// --- Observability (all optional) ---
// SEED values only: the server copies them into its database on first boot, after which the
// in-app Admin -> Settings UI is AUTHORITATIVE and overrides them (and the values persist
// across a re-provision, since they live in the DB). Leave empty to configure in-app instead.
// Logging (Datadog) is supported:
// param loggingProvider       = 'DataDog'
// param datadogApiKey         = '<datadog-api-key>'   // prefer --parameters
// param datadogApplicationKey = '<datadog-app-key>'   // prefer --parameters
// param datadogServiceName    = 'broch'
// param datadogEnvironment    = 'production'
// param datadogSite           = 'us5.datadoghq.com'
// param otelServiceName       = 'broch'
// Telemetry (Application Insights) is EXPERIMENTAL / WIP — not yet fully supported:
// param telemetryProvider                   = 'ApplicationInsights'
// param applicationInsightsConnectionString = '<app-insights-connection-string>'  // prefer --parameters
// The license is activated IN-APP (Admin UI) after first sign-in.
// param centralServerUrl = 'https://api.broch.io'   // override only for a self-hosted central

// --- Optional ---
// param vmSize = 'Standard_B2ps_v2'  // ARM64; check family quota/availability in your region
// param brochVersion = 'latest'      // pin to the running version before any prod cutover
