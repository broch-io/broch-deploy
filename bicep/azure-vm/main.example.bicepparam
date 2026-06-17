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

// --- Existing database + master key (paired — see README's cutover warning) ---
param brochMasterKey = '<existing-master-key>' // prefer --parameters over committing
param databaseConnectionString = 'Host=broch-postgres.postgres.database.azure.com;Database=brochdb;Username=<user>;Password=<pw>;Ssl Mode=Require' // prefer --parameters

// --- Domain + TLS (bring your own domain) ---
param wildcardHostname = 'tunnels.example.com'
param acmeEmail = 'ops@example.com'
param cloudflareApiToken = '<cloudflare-zone-dns-token>' // Zone:Read + DNS:Edit; prefer --parameters over committing

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
