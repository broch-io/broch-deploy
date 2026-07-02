// Copy to parameters.bicepparam and fill in. parameters.bicepparam is gitignored
// because it holds secrets (master key, DB password, OAuth client secret).
//
// Deploy with:
//   az deployment group create \
//     --resource-group broch-rg \
//     --template-file mainTemplate.bicep \
//     --parameters parameters.bicepparam

using './mainTemplate.bicep'

// ── Required ─────────────────────────────────────────────────────────────────

param wildcardHostname = 'tunnels.example.com'

// At-rest encryption root. Customer-owned — Broch, LLC never sees it. Wraps the
// DataProtection keyring (IdP refresh tokens, persisted license token, usage
// blob). Rotating it invalidates anything DP-wrapped in the database.
// Generate with: openssl rand -base64 48
param masterKey = '<openssl rand -base64 48>'

// Identity provider — required at boot. Broch has no built-in local login, so
// no one can sign in (or finish first-run setup) until this is set. Your first
// admin signs in holding a role named in adminRoles.
// Guides: https://broch.io/docs/identity-providers/
param authProvider = 'Auth0' // AzureAd | EntraExternalId | Auth0 | Okta | Oidc
param authClientId = '<oauth-client-id>'
param authClientSecret = '<oauth-client-secret>'
// broch_admin is an example — replace with admin group(s)/role(s) from your
// own IdP that your first admin actually holds. Comma-separated; holding any
// listed role grants admin.
param adminRoles = 'broch_admin'

// Set the value(s) your provider needs; leave the rest at their empty defaults:
//   Auth0 / Okta:     authDomain    = 'your-tenant.auth0.com' / 'your-org.okta.com'
//   AzureAd / Entra:  authTenantId  = '...'  +  authInstance = 'https://login.microsoftonline.com/'
//   Generic Oidc:     authAuthority = '<issuer URL serving /.well-known/openid-configuration>'
// param authDomain = ''
// param authTenantId = ''
// param authInstance = ''
// param authAuthority = ''
// param authAudience = ''
// param authScopes = ''

// ── Optional (defaults shown) ────────────────────────────────────────────────

// A Broch license is activated in-app on first sign-in (Admin → License) — there
// is no license parameter. Buy a license at https://broch.io/pricing.

// param databaseMode = 'Embedded'        // 'Embedded' = evaluation only: ephemeral sidecar, data
//                                        // lost on revision restarts/upgrades. 'Shared' (BYO
//                                        // managed Postgres) is the production shape.
// param databaseConnectionString = ''    // required for Shared mode
// param databasePassword = ''            // Embedded sidecar password — auto-generated when omitted
// param containerImage = 'ghcr.io/broch-io/broch:1.26.0'  // defaults to a pinned version; set a newer tag to upgrade
// param centralServerUrl = 'https://api.broch.io'

// Custom domain + wildcard TLS (see README — Azure managed certs don't issue
// wildcards, so a wildcard cert is supplied as a base64 PFX here).
// param customDomainHostname = 'tunnels.example.com'
// param customDomainWildcardHostname = '*.tunnels.example.com'
// param sslCertificatePfxBase64 = '<base64-encoded PFX>'
// param sslCertificatePassword = '<pfx-password>'
