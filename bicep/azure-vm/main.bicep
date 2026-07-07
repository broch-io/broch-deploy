// Broch — Azure VM (Bicep). Boots the canonical with-postgres-external + Caddy compose
// stack on an Ubuntu 24.04 VM. The VM path for Azure (alongside the ACA Bicep), for both
// self-hosting (databaseMode=Existing, bring your own PostgreSQL) and the marketplace
// one-click offer (databaseMode=Managed, provisions a PostgreSQL Flexible Server here).
// See README.md.
// Copyright (c) 2026 Broch, LLC. All rights reserved.

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Base name for the VM and its resources.')
param vmName string = 'broch'

@description('VM size. Default is x86 burstable (widely available). For ARM64 (cheaper, where capacity exists) pick an Ampere size (e.g. Standard_D2ps_v6) AND set imageSku to the arm64 SKU — the broch image is multi-arch.')
param vmSize string = 'Standard_B2s'

@description('Ubuntu image SKU — must match the VM architecture: "server" for x86 sizes, "server-arm64" for ARM (Ampere) sizes.')
param imageSku string = 'server'

@description('Admin username for the VM.')
param adminUsername string = 'broch'

@description('Optional, advanced. BYO SSH public key for break-glass access. Leave empty (default) and the VM is provisioned with a generated password instead — Broch is managed via `az vm run-command` / Azure Serial Console and needs no SSH. Setting a key switches the VM to key-only auth.')
param adminSshPublicKey string = ''

@description('Optional. AAD object ID of a user/group to grant read access to the generated break-glass VM password (Key Vault Secrets User, scoped to JUST that secret) so you can retrieve it without a manual role grant. Only applies when no SSH key is supplied (otherwise there is no break-glass password). It deliberately does NOT grant the app secrets (master key, DB credential, IdP secret, DNS tokens) — those are read only by the VM managed identity; grant yourself vault-level access manually if you need to inspect them. Empty (default) grants nothing.')
param adminObjectId string = ''

@description('Principal type of adminObjectId — set Group if it is an AAD group, or ServicePrincipal for a CI/CD managed identity / service principal. Lets ARM skip a type lookup that can race AAD replication and fail the role assignment.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param adminObjectType string = 'User'

@description('DNS zone you own, e.g. example.com — the parent domain Broch builds tunnel URLs under. This is the ZONE ONLY, not the full tunnel host: put the tunnel label in shareSubdomain below (dnsZone=example.com + shareSubdomain=tunnels), NOT dnsZone=tunnels.example.com. You must control this zone at a supported DNS provider (see README). Combined with shareSubdomain, it fixes the public hostname: Broch serves <shareSubdomain>.<dnsZone> and *.<shareSubdomain>.<dnsZone>.')
@minLength(1)
param dnsZone string

@description('Subdomain of dnsZone that hosts the public tunnel URLs. Default "tunnels" → Broch serves tunnels.<dnsZone> and *.tunnels.<dnsZone>. Leave EMPTY to serve tunnels at the zone apex itself (<dnsZone> and *.<dnsZone>). Usually a single label; a dotted value (e.g. "a.b") is accepted for a deeper subdomain.')
param shareSubdomain string = 'tunnels'

@description('Advanced. The DNS zone that actually OWNS the records, when it differs from dnsZone — i.e. the tunnel host lives on a DELEGATED subdomain that is its own DNS zone (e.g. dnsZone=example.com for the URLs, but the delegated zone is share.example.com). Leave EMPTY (default) for the common case where dnsZone IS the DNS zone. When set, auto-DNS writes the A records into THIS zone and derives the record labels as the host relative to it — the same zone the ACME/cert path already resolves, so a valid cert can no longer coexist with an A-record write that 404s. The Azure Marketplace wizard fills this from the DNS zone you pick; direct-Bicep users set it only for a delegated zone.')
param dnsZoneName string = ''

// --- TLS. Auto = Caddy auto-issues + renews the wildcard via ACME DNS-01 (pick a
// dnsProvider). Byo = you supply the wildcard cert + key, no ACME. ---
@allowed([
  'Auto'
  'Byo'
])
@description('Auto: Caddy auto-issues the wildcard via ACME DNS-01 (set dnsProvider). Byo: supply your own wildcard cert + key.')
param certMode string = 'Auto'

@allowed([
  'Cloudflare'
  'AzureDns'
  'AzureDnsServicePrincipal'
  'Route53'
  'GoogleCloudDns'
  'DigitalOcean'
])
@description('DNS-01 provider when certMode=Auto. AzureDns uses the VM\'s managed identity and the template auto-grants it DNS Zone Contributor (needs Owner/UAA on the zone RG). Every other provider authenticates with a credential you supply — no role assignment, so Contributor is enough to deploy.')
param dnsProvider string = 'Cloudflare'

// --- Automatic DNS records. Auto = the appliance creates + maintains the apex + wildcard
// A records itself; Manual = you own the records (required if anything fronts this VM). ---
@allowed([
  'Auto'
  'Manual'
])
@description('Auto (default): the appliance auto-creates and maintains the apex + wildcard A records pointing at this VM\'s public IP (deploy → sign in), reusing the dnsProvider credential. Manual: you create the A records yourself — required when a load balancer, reverse proxy, or NAT gateway sits IN FRONT of this VM (its public IP is then not what clients should resolve to), or when you manage DNS out-of-band. certMode=Byo forces Manual (no DNS credential).')
param dnsAutoRecords string = 'Auto'

@description('Email Let\'s Encrypt notifies about cert-renewal failures (certMode=Auto).')
param acmeEmail string = ''

@description('Cloudflare API token (Zone:Read + DNS:Edit) — dnsProvider=Cloudflare.')
@secure()
param cloudflareApiToken string = ''

@description('Resource group of the Azure DNS zone — dnsProvider=AzureDns or AzureDnsServicePrincipal (zone in this deployment\'s subscription).')
param dnsZoneResourceGroup string = ''

@description('Azure AD tenant ID of the service principal — dnsProvider=AzureDnsServicePrincipal.')
param azureTenantId string = ''

@description('Service-principal (app registration) client ID, pre-granted DNS Zone Contributor on the zone — dnsProvider=AzureDnsServicePrincipal.')
param azureClientId string = ''

@description('Service-principal client secret — dnsProvider=AzureDnsServicePrincipal.')
@secure()
param azureClientSecret string = ''

@description('AWS access key ID for a principal with Route 53 list+change rights on the zone — dnsProvider=Route53.')
@secure()
param awsAccessKeyId string = ''

@description('AWS secret access key — dnsProvider=Route53.')
@secure()
param awsSecretAccessKey string = ''

@description('GCP project ID hosting the Cloud DNS zone — dnsProvider=GoogleCloudDns.')
param gcpProject string = ''

@description('Base64-encoded GCP service-account JSON key (roles/dns.admin on the zone) — dnsProvider=GoogleCloudDns.')
@secure()
param gcpCredentialsJson string = ''

@description('DigitalOcean API token with DNS write scope — dnsProvider=DigitalOcean.')
@secure()
param doAuthToken string = ''

@description('Base64-encoded PEM fullchain (cert + intermediates) covering the apex + wildcard — certMode=Byo.')
@secure()
param tlsCertificate string = ''

@description('Base64-encoded PEM private key for the wildcard cert — certMode=Byo.')
@secure()
param tlsCertificateKey string = ''

@description('Broch server image tag. Defaults to a concrete pinned version (NOT latest) so a redeploy never silently rolls the box across an EF-migration boundary; new releases of this template bump this default. Set to a newer tag to upgrade deliberately, or "latest" to float. 1.29.0+ is required for dnsAutoRecords=Auto (it serves /internal/public-ip, which caddy-dynamicdns polls to write the A records).')
param brochVersion string = '1.29.0'

@description('Broch server image repository (no tag). Default is the public image. Override for a private mirror or a pre-release/beta image you have been granted access to — set the registry* params below for the pull credential.')
param brochImage string = 'ghcr.io/broch-io/broch'

@description('Container registry host — defaults to ghcr.io (where Broch images live). Only used when registryPassword is set.')
param registryServer string = 'ghcr.io'

@description('Registry login username — defaults to a value GHCR accepts with a valid token. Only used when registryPassword is set.')
param registryUsername string = 'broch'

@description('Registry token/password. Empty (default) = the image is public, no login. Set this (only this) to pull a private pre-release/beta image — the server/username already default to GHCR.')
@secure()
param registryPassword string = ''

@description('CIDR allowed to reach SSH (port 22). Empty (default) creates NO inbound SSH rule — the box is managed via `az vm run-command` / Azure Serial Console, the secure default. Set a CIDR (e.g. your admin network) to allow SSH break-glass.')
param sshAllowedCidr string = ''

@description('REQUIRED on a first deployment (only a reuseExistingSecrets redeploy may leave it empty). The at-rest encryption root (BROCH_MASTER_KEY) — customer-owned, Broch never sees it. Generate a strong value with `openssl rand -base64 48` and store it in your own secret store; the SAME value must be supplied on every (re)deploy — or left empty with reuseExistingSecrets=true to reuse the stored one. For an Existing database this MUST be the key that database was encrypted with — a different key cannot decrypt its Data Protection keyring (recoverable: users re-auth and the license re-activates, but disruptive). No @minLength: an empty value must be accepted for the redeploy path; the server still rejects values under 32 bytes at boot, and a first deploy without a key fails closed at the boot-fetch (see kvSecretMap).')
@secure()
param brochMasterKey string = ''

@description('Retry a FAILED deployment in the SAME resource group without re-entering secrets. The deploy-time secrets survive a failed deployment in this deployment\'s Key Vault (written early, deterministic names — see kvName), so a retry can reuse them: set true and leave the vault-backed secret params (brochMasterKey, authClientSecret, DNS credentials, databaseConnectionString, localDbAdminPassword) EMPTY — blank then means "keep the stored value" instead of "overwrite with nothing". Repeat the SAME non-secret selections as the failed attempt, and re-supply anything that lives in customData rather than the vault (BYO TLS cert/key, GCP credentials JSON, registry token) plus — Managed mode — the SAME postgresAdminPassword. Assumes the first attempt supplied an OAuth client secret whenever authProvider is set (the marketplace wizard always does): a SECRETLESS-auth deployment must NOT use reuseExistingSecrets — its retry would list an auth-client-secret that was never stored and halt at the boot-fetch (see kvSecretMap). Leave false (default) on a first deployment: first deploys must supply real values (into a FRESH resource group, blank-with-false writes nothing for the boot-fetch to read; an RG with a prior deploy would silently reuse ITS stored values).')
param reuseExistingSecrets bool = false

@description('Internal — do not set. Entropy for the generated break-glass VM password (used only when no SSH key is supplied).')
@secure()
param vmPasswordSeed string = newGuid()

// --- Database. Existing = connect to your own PostgreSQL; Managed = provision an Azure
// Database for PostgreSQL Flexible Server in this deployment (the marketplace one-click). ---
@allowed([
  'Existing'
  'Managed'
  'Local'
])
@description('Existing: connect to the PostgreSQL you supply in databaseConnectionString. Managed: provision an Azure PostgreSQL Flexible Server in this deployment. Local: run PostgreSQL on this VM (the bundled with-postgres compose) on a small dedicated data disk — zero DB prerequisites, but YOU manage backups (no automated backups/PITR; see README).')
param databaseMode string = 'Existing'

@description('Npgsql connection string for your existing PostgreSQL (Existing mode). Ignored when databaseMode=Managed/Local.')
@secure()
param databaseConnectionString string = ''

@description('Size (GiB) of the dedicated data disk that holds the Local PostgreSQL data (databaseMode=Local). Broch\'s database is tiny; the default suits typical use — size up only if you retain large audit/request-log history. The disk is a separate resource, so the database survives VM reboots and recreation. Pick the size at first deploy: INCREASING it on a later redeploy resizes the Azure disk but does NOT auto-grow the ext4 filesystem — run `sudo resize2fs /dev/disk/azure/scsi1/lun0` on the VM afterward (and note some disk tiers require a VM deallocate to resize). Shrinking is not supported.')
@minValue(4)
@maxValue(1024)
param dataDiskSizeGb int = 4

@description('Optional password for the bundled Local PostgreSQL (databaseMode=Local). Leave empty for a zero-config default DERIVED from the resource group + VM name. That default is computable by anyone with Reader on the subscription, so SET an explicit value for any deployment where the VM identity could be compromised (Postgres has no host port, so the practical blast radius is limited to in-container code execution). If you set one, STORE IT and re-supply the SAME value on any from-scratch recreate of a Local-mode VM (Postgres keeps the password from when its data dir was first initialised). Ignored for Existing/Managed.')
@secure()
param localDbAdminPassword string = ''

@description('Admin password for the provisioned PostgreSQL (Managed mode). 8-128 chars; at least 3 of lower/upper/digit/symbol.')
@secure()
param postgresAdminPassword string = ''

@allowed([
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_D2ds_v5'
  'Standard_D4ds_v5'
])
@description('Compute size for the provisioned PostgreSQL (Managed mode).')
param postgresSkuName string = 'Standard_B1ms'

// --- Identity provider (boot floor). Set what your provider needs; leave the rest ''. ---
@description('Auth0 | AzureAd | EntraExternalId | Okta | Oidc')
param authProvider string = ''
param authClientId string = ''
@secure()
param authClientSecret string = ''
@description('Comma-separated admin role(s); a user holding any one is granted admin.')
param authAdminRoles string = ''
param authDomain string = ''
param authTenantId string = ''
param authInstance string = ''
param authAuthority string = ''
param authAudience string = ''

// Managed mode provisions a PRIVATE Flex Server below; its connection string is built from
// the server's deterministic FQDN (no resource reference, so it stays valid when Managed is
// off) — the same construction the azure-container-apps template uses.
var pgServerName = '${vmName}-pg'
var pgAdminUser = 'brochadmin'
var pgDatabaseName = 'brochdb'
// The private DNS zone is required for VNet injection but must NOT be used to build the
// connection Host: Azure registers the zone's A record under an instance-specific label, not
// under <serverName>, so '<serverName>.<zone>' does not resolve. The name that resolves inside
// the VNet is the server's real FQDN, <serverName>.postgres.database.azure.com — Azure DNS
// aliases it to the zone record.
var pgDnsZone = '${vmName}-db.private.postgres.database.azure.com'
var pgHost = '${pgServerName}.postgres.database.azure.com'
var managedConnectionString = 'Host=${pgHost};Port=5432;Database=${pgDatabaseName};Username=${pgAdminUser};Password=${postgresAdminPassword};SSL Mode=Require'
var effectiveConnectionString = databaseMode == 'Managed' ? managedConnectionString : databaseConnectionString

// Local mode: PostgreSQL runs ON the VM (the bundled with-postgres compose). cloud-init injects
// this password; the compose builds its own connection string from it. The path passed to
// loadTextContent must be a compile-time literal, so we load BOTH composes and pick at deploy.
// The password is DERIVED (not random) so it is STABLE across a from-scratch reprovision — same
// subscription + RG + vmName => same password (uniqueString hashes resourceGroup().id, which includes
// the subscription GUID, so MOVING the RG to another subscription changes it — pin localDbAdminPassword
// before such a migration). That stability is essential: PostgreSQL ignores POSTGRES_PASSWORD after the
// data dir is initialised, so a recreated VM must present the SAME password to the surviving disk's
// database (a fresh newGuid() would lock broch out of its own surviving data). The bundled
// PostgreSQL is not network-exposed (no host port, docker-internal only), so the derived default is
// safe; an operator who wants a credential NOT derivable from ARM metadata (or one stable across a
// subscription move) can supply localDbAdminPassword (re-supply the same value on recreate).
var localDbPassword = empty(localDbAdminPassword) ? '${uniqueString(resourceGroup().id, vmName, 'broch-local-db')}X9' : localDbAdminPassword
var composeExternal = loadTextContent('../../docker-compose/with-postgres-external/docker-compose.yml')
var composeLocal = loadTextContent('../../docker-compose/with-postgres/docker-compose.yml')
var selectedCompose = databaseMode == 'Local' ? composeLocal : composeExternal

// The master key is always customer-supplied — never generated — so a (re)deploy can't mint a
// different key that fails to decrypt an existing database. (Empty is allowed ONLY for the
// reuseExistingSecrets redeploy path, which keeps the stored key rather than writing a new one.)
// No SSH key supplied => provision a generated break-glass password (Serial Console).
// Azure complexity needs >=3 of upper/lower/digit/special. The GUID seed always supplies
// lowercase/digit plus hyphens (which Azure counts as special); appending an uppercase letter
// and a digit guarantees the third class — without a password-shaped literal that trips
// secret scanners (the entropy is the GUID, not the suffix).
var usePassword = empty(adminSshPublicKey)
var generatedVmPassword = '${vmPasswordSeed}X9'
// The Key Vault is now ALWAYS created: it holds the high-value deploy-time secrets (master key, DB
// credential, IdP secret, DNS-01 tokens) that the VM's user-assigned managed identity reads at boot,
// instead of those values living in customData (base64, ARM-Reader-readable). The generated break-glass
// password (no-SSH-key mode) lives in a SECOND vault the VM identity can't read (see bgKeyVault). (The BYO
// TLS cert/key, GCP creds JSON, and registry token are NOT yet migrated -- they remain in customData; see
// the README follow-up note.) So every deploy creates a Key Vault -- two in no-SSH-key mode -- each with
// the 7-day soft-delete-on-teardown behaviour (see README).

// --- TLS config selection ---
// Auto mode: build the tls.caddy fragment the Caddyfile imports, per DNS provider. All provider
// modules are compiled into the broch-caddy image (see Caddy.Dockerfile), so this is just config.
// Byo mode: the BYO-cert Caddyfile (:443 catch-all) reads the supplied cert from /etc/caddy/certs;
// tls.caddy is unused. Caddyfiles come from broch-deploy (single source).
// Azure managed identity = omit tenant/client/secret; service principal = include them.
// The per-provider tls fragments (with DNS-01 propagation tuning baked in) come from the CANONICAL
// single source docker-compose/caddy-tls/<provider>.caddy -- one definition, consumed by every deploy
// target; scripts/check-caddy-dns-sync.py fails CI if any target drifts from it. loadTextContent needs
// a compile-time-literal path, so load all variants and ternary-select (like selectedCompose below).
// Azure VM uses the explicit-keys route53 fragment (no instance role here, unlike the AWS appliance).
var tlsCloudflare = loadTextContent('../../docker-compose/caddy-tls/cloudflare.caddy')
var tlsAzureMi = loadTextContent('../../docker-compose/caddy-tls/azure-mi.caddy')
var tlsAzureSpn = loadTextContent('../../docker-compose/caddy-tls/azure-spn.caddy')
var tlsRoute53 = loadTextContent('../../docker-compose/caddy-tls/route53.caddy')
var tlsGoogle = loadTextContent('../../docker-compose/caddy-tls/googleclouddns.caddy')
var tlsDigitalOcean = loadTextContent('../../docker-compose/caddy-tls/digitalocean.caddy')
var autoTlsCaddy = dnsProvider == 'Cloudflare' ? tlsCloudflare : (dnsProvider == 'AzureDns' ? tlsAzureMi : (dnsProvider == 'AzureDnsServicePrincipal' ? tlsAzureSpn : (dnsProvider == 'Route53' ? tlsRoute53 : (dnsProvider == 'GoogleCloudDns' ? tlsGoogle : tlsDigitalOcean))))
var tlsCaddyContent = certMode == 'Byo' ? '# BYO-cert mode: TLS is set in the Caddyfile; this fragment is unused.\n' : autoTlsCaddy
// The ONE public hostname, composed from the zone + share subdomain — a single structural
// definition, so there is no separate full-hostname param that could disagree with the zone. Empty
// shareSubdomain => the share lives at the zone apex. Fanned out to both Caddy and broch in the
// compose (via BROCH_WILDCARD_HOSTNAME); the auto-DNS runcmd derives the record labels from the
// zone + subdomain directly.
var wildcardHostname = empty(shareSubdomain) ? dnsZone : '${shareSubdomain}.${dnsZone}'
// Automatic apex+wildcard A-record management (dynamic-dns.caddy). Byo-cert has no DNS
// credential, so it can never auto-manage records — force Manual there. cloud-init renders
// the caddy-dynamicdns block from this + dnsProvider + the zone + share subdomain when Auto.
var effectiveDnsAuto = certMode == 'Byo' ? 'Manual' : dnsAutoRecords
// Mirror selectedCompose's mode branch so a Local-mode VM loads the Caddyfile from the same template
// dir as its compose. The Auto-mode Caddyfiles are byte-identical today, so this is drift-insurance,
// not a behaviour change; Byo mode uses its own variant.
var caddyfileContent = certMode == 'Byo' ? loadTextContent('../../docker-compose/with-postgres-byo-cert/Caddyfile') : (databaseMode == 'Local' ? loadTextContent('../../docker-compose/with-postgres/Caddyfile') : loadTextContent('../../docker-compose/with-postgres-external/Caddyfile'))

// Both Azure DNS modes need the subscription id. Only the managed-identity mode gets a VM
// identity + the auto role grant; the service-principal mode (and every non-Azure provider)
// authenticates with the supplied credential, so no identity and no role assignment.
var usesAzureDns = certMode == 'Auto' && (dnsProvider == 'AzureDns' || dnsProvider == 'AzureDnsServicePrincipal')
var azureDnsManagedIdentity = certMode == 'Auto' && dnsProvider == 'AzureDns'
var azureSubscriptionId = usesAzureDns ? subscription().subscriptionId : ''
// GCP Cloud DNS: Caddy reads the service-account JSON via GOOGLE_APPLICATION_CREDENTIALS (ADC);
// cloud-init writes it (base64) into the certs dir already mounted into the Caddy container.
var gcpCredsPath = (certMode == 'Auto' && dnsProvider == 'GoogleCloudDns') ? '/etc/caddy/certs/gcp-sa.json' : ''

// cloud-init.yaml carries __TOKEN__ placeholders; substitute them before base64.
// Token→value table folded over the file with reduce(). The base64 blobs are pure
// base64 (no underscores), so they never collide with a __TOKEN__ placeholder.
var cloudInitTokens = [
  // Canonical compose stack, embedded VERBATIM (base64) from the shared docker-compose template
  // — single source of truth, so the VM runs the same bytes as a docker-direct customer and the
  // two cannot drift. with-postgres-external normally; with-postgres (bundled DB) for Local mode.
  ['__COMPOSE_B64__', base64(selectedCompose)]
  ['__CADDYFILE_B64__', base64(caddyfileContent)]
  ['__TLS_CADDY_B64__', base64(tlsCaddyContent)]
  // Same null-render guard as __GCP_SA_JSON_B64__ below: tlsCertificate/tlsCertificateKey are
  // empty in the DEFAULT certMode=Auto path, which would render `content:` (YAML null) and can
  // abort the whole write_files step. 'e30=' (base64 '{}') keeps the entry a valid scalar; the
  // files are inert in Auto mode (Caddy auto-issues and never reads them).
  ['__TLS_CERT_B64__', empty(tlsCertificate) ? 'e30=' : tlsCertificate]
  ['__TLS_KEY_B64__', empty(tlsCertificateKey) ? 'e30=' : tlsCertificateKey]
  // .env values — the template's .env.example surface (friendly names; the compose
  // fans BROCH_WILDCARD_HOSTNAME out to both Caddy and broch's API__WILDCARDHOSTNAME).
  ['__BROCH_VERSION__', brochVersion]
  ['__BROCH_IMAGE__', brochImage]
  ['__REGISTRY_SERVER__', registryServer]
  ['__REGISTRY_USERNAME__', registryUsername]
  ['__REGISTRY_PASSWORD__', registryPassword]
  ['__WILDCARD_HOSTNAME__', wildcardHostname]
  // Seed for broch's own public-IP setting (Api:PublicIp): the Static public IP this template
  // allocated, known here at deploy time. broch serves it to caddy-dynamicdns (which writes the
  // apex+wildcard A records), and an admin can override it at runtime — so auto-DNS points at the
  // IP we KNOW rather than one caddy has to discover. Always populated (unconditional); inert in
  // Manual/Byo, where the dynamic-dns.caddy stub has no dynamic_dns block so nothing fetches it.
  // Non-secret (it's published in DNS anyway), so plain in .env is fine.
  ['__PUBLIC_IP__', publicIp.properties.ipAddress]
  ['__CADDY_ACME_EMAIL__', acmeEmail]
  // Automatic A-record management: cloud-init renders /opt/broch/dynamic-dns.caddy from these.
  // effectiveDnsAuto is 'Manual' whenever certMode=Byo (no DNS credential to manage records).
  ['__DNS_AUTO_RECORDS__', effectiveDnsAuto]
  ['__DNS_PROVIDER__', dnsProvider]
  // dnsZone + shareSubdomain are free-text (bicep can't AllowedPattern-validate a string param like
  // CFn does), and the auto-DNS runcmd EXECUTES them, so pass them base64-encoded and decode at
  // runtime — base64 is [A-Za-z0-9+/=] only, so a `$(...)`/backtick/quote in the value can't break
  // out of the shell. (The raw __WILDCARD_HOSTNAME__ above stays — it's the composed host, and it
  // only lands in the non-executed .env content, where it's inert.)
  ['__DNS_ZONE_B64__', base64(dnsZone)]
  ['__SHARE_SUBDOMAIN_B64__', base64(shareSubdomain)]
  // The zone auto-DNS actually writes into — dnsZone unless a delegated subzone was supplied. Empty
  // in the common case; the render falls back to dnsZone then, so existing deploys are unchanged.
  ['__DNS_ZONE_NAME_B64__', base64(dnsZoneName)]
  // The __AZURE_*__ token names are intentionally NOT renamed — they are internal
  // substitution placeholders. The .env var NAMES they populate were renamed to
  // AZURE_DNS_* in cloud-init.yaml; "correcting" this apparent mismatch breaks substitution.
  ['__AZURE_SUBSCRIPTION_ID__', azureSubscriptionId]
  ['__AZURE_DNS_RESOURCE_GROUP__', dnsZoneResourceGroup]
  ['__AZURE_TENANT_ID__', azureTenantId]
  ['__AZURE_CLIENT_ID__', azureClientId]
  ['__GCP_PROJECT__', gcpProject]
  ['__GOOGLE_APP_CREDS_PATH__', gcpCredsPath]
  // 'e30=' (base64 of '{}') when no GCP creds: an empty value renders `content: ` in the
  // cloud-init write_files entry, which YAML parses as null and can TypeError the whole
  // write_files step (no .env written → unconfigured VM). A valid-but-empty JSON keeps the
  // file parseable; Caddy only reads it in GoogleCloudDns mode, so it's inert otherwise.
  ['__GCP_SA_JSON_B64__', empty(gcpCredentialsJson) ? 'e30=' : gcpCredentialsJson]
  // Drives the cloud-init data-disk mount: Local waits for + requires the disk (a missing disk is a
  // loud failure, never a silent fall-through onto the OS disk); other modes skip the block entirely.
  ['__LOCAL_DB__', databaseMode == 'Local' ? 'true' : 'false']
  ['__AUTH_PROVIDER__', authProvider]
  ['__AUTH_CLIENT_ID__', authClientId]
  ['__AUTH_ADMIN_ROLES__', authAdminRoles]
  ['__AUTH_DOMAIN__', authDomain]
  ['__AUTH_TENANT_ID__', authTenantId]
  ['__AUTH_INSTANCE__', authInstance]
  ['__AUTH_AUTHORITY__', authAuthority]
  ['__AUTH_AUDIENCE__', authAudience]
  // Key Vault boot-fetch (replaces the secret values that used to be substituted into .env here, so
  // they never enter customData). cloud-init reads each named secret with the VM's user-assigned
  // identity and appends it to .env. __KV_SECRETS__ lists ENVKEY=secret-name pairs for exactly the
  // secrets that exist (assembled in kvSecretMap above), ';'-joined.
  ['__KV_NAME__', kvName]
  ['__UAI_CLIENT_ID__', vmIdentity.properties.clientId]
  ['__KV_SECRETS__', kvSecretMap]
]
var cloudInit = reduce(
  cloudInitTokens,
  loadTextContent('cloud-init.yaml'),
  (cur, t) => replace(string(cur), t[0], t[1]))

// SSH is opt-in: only when sshAllowedCidr is set. Empty (default) = no inbound 22 at all
// (manage via `az vm run-command` / Serial Console). Default-closed beats the old `*`.
var sshRules = empty(sshAllowedCidr) ? [] : [
  {
    name: 'SSH'
    properties: {
      priority: 1000
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: sshAllowedCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
    }
  }
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: concat(sshRules, [
      {
        name: 'HTTP'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'HTTPS'
        properties: {
          priority: 1020
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ])
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${vmName}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        // Delegated to PostgreSQL Flexible Server for VNet injection (Managed DB mode).
        // Unused in Existing mode. The VM (default subnet) reaches the DB intra-VNet.
        name: 'postgres'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'pgflex'
              properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
            }
          ]
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${vmName}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

// --- Managed database (databaseMode=Managed only): a PRIVATE Azure PostgreSQL Flexible
// Server, VNet-injected into the delegated subnet with a private DNS zone — NO public
// endpoint; only the VM (same VNet) can reach it. broch connects over SSL as the server
// admin to a provisioned 'brochdb' — the "external Postgres" the compose expects. ---
resource postgresDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (databaseMode == 'Managed') {
  name: pgDnsZone
  location: 'global'
}

resource postgresDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (databaseMode == 'Managed') {
  parent: postgresDnsZone
  name: '${vmName}-pg-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = if (databaseMode == 'Managed') {
  name: pgServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: startsWith(postgresSkuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
  }
  properties: {
    version: '16'
    administratorLogin: pgAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    // Private access: injected into the delegated subnet + resolvable via the private DNS
    // zone. No public endpoint (publicNetworkAccess can't be Enabled with a delegated subnet).
    network: {
      delegatedSubnetResourceId: vnet.properties.subnets[1].id
      privateDnsZoneArmResourceId: postgresDnsZone.id
    }
  }
  dependsOn: [ postgresDnsLink ]
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = if (databaseMode == 'Managed') {
  parent: postgres
  name: pgDatabaseName
}

// --- Customer-owned secret store. ALWAYS created now: it holds the deploy-time secrets the VM's
// user-assigned identity reads at BOOT (master key, DB credential, IdP secret, DNS-01 tokens) instead of
// those values living in customData (base64, ARM-Reader-readable). The generated break-glass VM password
// is kept in a SEPARATE vault (bgKeyVault, below) the VM identity canNOT read -- so a broch RCE can't use
// the VM identity to lift the host break-glass password. ACCESS-POLICY mode (not RBAC); this deployment
// writes the secrets via the control plane and grants the VM read via the vault's access policy -- both
// Contributor-covered, so the secrets path needs no Owner/UAA (see the keyVault resource for the why).
// The master key is customer-supplied and never transits Broch/Central (born in the customer tenant); it
// is stored here only so the VM can read it the same way as the rest. ---
// Two vaults per broch, both named for THIS deployment (vmName) + role and SHARING one id, so they read as
// an obvious pair: <vmName>-app-<id> (app secrets, access-policy) and <vmName>-bg-<id> (break-glass, RBAC).
// The <id> is not cosmetic randomness -- Key Vault names are unique across ALL of Azure, so a bare
// <vmName>-app would collide whenever two deployments share a vmName (the Marketplace default is 'broch').
// uniqueString(rg.id, vmName) is DETERMINISTIC: the same deployment always recomputes the same names, so a
// redeploy re-targets the same vaults (no churn); a different RG/subscription gets distinct ones. These
// names are also distinct from the old single-vault template's <vmName>-kv-<hash>, so on an UPGRADE the app
// vault is created DIRECTLY in access-policy mode -- never an RBAC->access-policy flip, which would need
// Owner/UAA and break Contributor-deployability. Length <= 24: take(vmName,12) + '-app-' (5) + id (7) = 24.
var kvId = take(uniqueString(resourceGroup().id, vmName), 7)
var kvBaseName = take(vmName, 12)
var kvName = '${kvBaseName}-app-${kvId}'
var bgKvName = '${kvBaseName}-bg-${kvId}'

// User-assigned managed identity the VM uses to (a) read the deploy-time secrets from Key Vault at boot
// and (b) complete Caddy's AzureDns ACME challenge (dnsProvider=AzureDns). User-assigned, NOT
// system-assigned, on purpose: its principalId exists BEFORE the VM, so the app vault's access policy
// (below) names it and is in place the instant the vault is created -- cloud-init's boot-time secret
// fetch then does not race grant propagation. Declared ahead of the vault so the vault can reference it.
resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${vmName}-id'
  location: location
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    // Access-policy mode (NOT RBAC). The VM identity's read grant is a data-plane PROPERTY of the vault,
    // written with Contributor on the vault -- so the deploy needs NO Microsoft.Authorization/
    // roleAssignments/write (i.e. Owner / User Access Administrator). The secret WRITES below are ARM
    // control-plane ops, Contributor-covered either way. 'get' only: the boot-fetch reads named secrets,
    // never lists. This keeps the appliance -- and the Azure Marketplace solution template compiled from
    // this exact file -- deployable by a plain Contributor, which RBAC mode silently broke: an
    // unconditional Key Vault Secrets User role assignment forced Owner/UAA on EVERY deploy. Bonus: access
    // policies are enforced by the vault directly, with no AAD-RBAC replication lag -- shrinking the
    // ~10-min propagation window the boot-fetch retry loop exists to survive (the loop stays as
    // belt-and-suspenders). The break-glass vault (bgKeyVault) stays RBAC: its grant is conditional on
    // adminObjectId, which the Marketplace never sets, so it does not raise the deploy floor.
    // TRADEOFF: accessPolicies/write is ALSO in Contributor, so anyone with Contributor on this RG can add
    // themselves to the policy and read these secrets. That is NOT a new exposure -- a Contributor already
    // has VM-level access (az vm run-command -> cat /opt/broch/.env) -- so the vault is not a boundary against
    // RG Contributors either way. The win is vs a subscription READER (customData was base64 Reader-decodable;
    // the vault is not) and the break-glass password, which stays in the RBAC bgKeyVault a Contributor cannot
    // self-grant. Lock down RG Contributor membership accordingly (README "Secrets & break-glass").
    enableRbacAuthorization: false
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: vmIdentity.properties.principalId
        permissions: { secrets: [ 'get' ] }
      }
    ]
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Separate vault holding ONLY the generated break-glass VM password (no-SSH-key mode). The VM's
// user-assigned identity has NO grant here -- so a broch RCE that mints an IMDS vault token cannot read
// the host break-glass password. Only the operator (adminObjectId) can, via the secret-scoped grant below.
resource bgKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (usePassword) {
  name: bgKvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// NOT rewritten on a reuseExistingSecrets redeploy: vmPasswordSeed is newGuid(), so this run's
// generatedVmPassword differs from the one the (already-provisioned) VM actually has — Azure ignores an
// adminPassword change on a VM re-PUT, so rewriting the secret would rotate the VAULT copy away from the
// REAL password and break Serial Console break-glass. Skipping keeps them in sync for the common retry
// (the VM survived the failed attempt). Known edge: if the failure predated the VM itself, the retried
// VM gets a fresh password while the vault keeps attempt 1's — recover with `az vm user update` if
// break-glass is ever needed there.
resource kvVmPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (usePassword && !reuseExistingSecrets) {
  parent: bgKeyVault
  name: 'vm-admin-password'
  properties: { value: generatedVmPassword }
}

// Deploy-time secrets the VM fetches at boot (kept OUT of customData). Each is created only when it has a
// value — so blank NEVER overwrites: on a reuseExistingSecrets redeploy the blank params simply leave the
// stored values from the failed attempt in place, and the boot-fetch list (kvSecretMap) names what SHOULD
// exist for the selected modes rather than what this run wrote.
resource secMasterKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(brochMasterKey)) {
  parent: keyVault
  name: 'broch-master-key'
  properties: { value: brochMasterKey }
}
// Managed gates on postgresAdminPassword, not effectiveConnectionString: managedConnectionString is a
// composed literal that is non-empty even with a BLANK password, so the old `!empty(effectiveConnectionString)`
// check would let a blank-password redeploy overwrite the good stored connection string with a Password=; one.
resource secDbConn 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if ((databaseMode == 'Managed' && !empty(postgresAdminPassword)) || (databaseMode == 'Existing' && !empty(databaseConnectionString))) {
  parent: keyVault
  name: 'db-connection-string'
  properties: { value: effectiveConnectionString }
}
// Skipped when a reuse redeploy supplies no explicit password: localDbPassword would fall back to the
// DERIVED default, and writing that would clobber a custom localDbAdminPassword stored by the first
// attempt (PostgreSQL keeps the password its data dir was initialised with — see localDbPassword above).
resource secPgPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (databaseMode == 'Local' && (!empty(localDbAdminPassword) || !reuseExistingSecrets)) {
  parent: keyVault
  name: 'postgres-password'
  properties: { value: localDbPassword }
}
resource secAuthSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(authClientSecret)) {
  parent: keyVault
  name: 'auth-client-secret'
  properties: { value: authClientSecret }
}
resource secCloudflare 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(cloudflareApiToken)) {
  parent: keyVault
  name: 'cloudflare-api-token'
  properties: { value: cloudflareApiToken }
}
resource secAzureDnsSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(azureClientSecret)) {
  parent: keyVault
  name: 'azure-dns-client-secret'
  properties: { value: azureClientSecret }
}
resource secAwsKeyId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(awsAccessKeyId)) {
  parent: keyVault
  name: 'aws-access-key-id'
  properties: { value: awsAccessKeyId }
}
resource secAwsSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(awsSecretAccessKey)) {
  parent: keyVault
  name: 'aws-secret-access-key'
  properties: { value: awsSecretAccessKey }
}
resource secDoToken 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(doAuthToken)) {
  parent: keyVault
  name: 'do-auth-token'
  properties: { value: doAuthToken }
}

// Optional: let the deployer read the BREAK-GLASS PASSWORD. Scoped to the break-glass VAULT (which holds
// ONLY vm-admin-password), so adminObjectId (e.g. a shared CI/CD principal) gains read on that and nothing
// else -- never the master key / DB credential / IdP secret / DNS tokens, which live in the app vault and
// are the VM identity's to read. Scoping to the vault (not the conditional secret resource) also avoids a
// conditional-scope mismatch some Bicep toolchains reject. Only meaningful when a break-glass password
// exists (no SSH key supplied); with an SSH key there is nothing to grant.
resource kvReadGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminObjectId) && usePassword) {
  scope: bgKeyVault
  name: guid(bgKeyVault.id, adminObjectId, 'kv-secrets-user')
  properties: {
    principalId: adminObjectId
    principalType: adminObjectType
    // Key Vault Secrets User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

// Boot-fetch map: ENVKEY=secret-name pairs for every secret that exists, ';'-joined. cloud-init splits
// this, fetches each from Key Vault via the VM identity, and appends KEY=value to /opt/broch/.env.
// Each entry is included when this run SUPPLIED the value — or, on a reuseExistingSecrets redeploy, when
// the selected mode/provider says the secret SHOULD already exist from the first attempt (the blank param
// wrote nothing this run, but the vault still holds the value). The selection conditions mirror what a
// valid first deploy of the same selections would have supplied, so the redeploy's customData comes out
// byte-identical to the first attempt's — which matters when the failure predated the VM: the retried VM
// then boot-fetches the full list. (On a VM that already exists, Azure ignores customData changes on
// re-PUT, so cloud-init neither reruns nor cares.) The boot-fetch fails closed on a missing secret — a
// reuse redeploy into an RG that never had a first attempt halts at the fetch rather than booting
// half-configured.
var kvSecretMap = join(filter([
  'BROCH_MASTER_KEY=broch-master-key'
  databaseMode == 'Local' ? 'POSTGRES_PASSWORD=postgres-password' : ((databaseMode == 'Managed' ? !empty(postgresAdminPassword) : !empty(databaseConnectionString)) || reuseExistingSecrets ? 'BROCH_DB_CONNECTION_STRING=db-connection-string' : '')
  !empty(authClientSecret) || (reuseExistingSecrets && !empty(authProvider)) ? 'AUTHENTICATION__CLIENTSECRET=auth-client-secret' : ''
  !empty(cloudflareApiToken) || (reuseExistingSecrets && certMode == 'Auto' && dnsProvider == 'Cloudflare') ? 'CLOUDFLARE_API_TOKEN=cloudflare-api-token' : ''
  !empty(azureClientSecret) || (reuseExistingSecrets && certMode == 'Auto' && dnsProvider == 'AzureDnsServicePrincipal') ? 'AZURE_DNS_CLIENT_SECRET=azure-dns-client-secret' : ''
  !empty(awsAccessKeyId) || (reuseExistingSecrets && certMode == 'Auto' && dnsProvider == 'Route53') ? 'AWS_ACCESS_KEY_ID=aws-access-key-id' : ''
  !empty(awsSecretAccessKey) || (reuseExistingSecrets && certMode == 'Auto' && dnsProvider == 'Route53') ? 'AWS_SECRET_ACCESS_KEY=aws-secret-access-key' : ''
  !empty(doAuthToken) || (reuseExistingSecrets && certMode == 'Auto' && dnsProvider == 'DigitalOcean') ? 'DO_AUTH_TOKEN=do-auth-token' : ''
], item => !empty(item)), ';')

// Dedicated data disk for the Local PostgreSQL (databaseMode=Local). A SEPARATE resource so the DB
// survives VM recreation: createOption Empty is create-once (a redeploy never wipes it), and the VM
// attaches it. Standard SSD is plenty for broch's tiny database.
resource localDataDisk 'Microsoft.Compute/disks@2023-10-02' = if (databaseMode == 'Local') {
  name: '${vmName}-data'
  location: location
  sku: { name: 'StandardSSD_LRS' }
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: dataDiskSizeGb
    // The disk holds the bundled Postgres data dir (pg_wal + all user state). Block the SAS-export
    // path so a Contributor on the RG can't `az disk grant-access` to download the raw ext4 image
    // out-of-band — the data is reachable only through the VM. publicNetworkAccess=Disabled is
    // belt-and-suspenders (DenyAll already covers it) and makes the hardened intent explicit.
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  // User-assigned identity ALWAYS (cloud-init reads the deploy-time secrets from Key Vault with it).
  // System-assigned is ADDED only for AzureDns managed-identity mode: Caddy's DefaultAzureCredential
  // (no client_id) picks the system-assigned identity that holds DNS Zone Contributor (granted below),
  // while cloud-init's KV fetch selects the user-assigned identity explicitly by client_id — so the two
  // never collide. The user-assigned identity exists before the app vault, so the vault's access policy
  // names it at creation and the boot-time fetch has an immediate (no-propagation-lag) data-plane grant.
  identity: {
    type: azureDnsManagedIdentity ? 'SystemAssigned, UserAssigned' : 'UserAssigned'
    userAssignedIdentities: { '${vmIdentity.id}': {} }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      // No SSH key => generated password (break-glass via Serial Console; inbound SSH stays
      // closed by default). BYO key => key-only auth, no password. The password derives from a
      // @secure() seed param; the var loses the secure flag, hence the suppression.
      #disable-next-line use-secure-value-for-secure-inputs
      adminPassword: usePassword ? generatedVmPassword : null
      linuxConfiguration: {
        disablePasswordAuthentication: !usePassword
        ssh: usePassword ? null : {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    // dataDisks is added via union() ONLY in Local mode, so the key is ABSENT (not []) otherwise.
    // This matters: in ARM incremental mode a VM PUT with dataDisks:[] declares a desired state of
    // ZERO disks and would DETACH an attached Local data disk if the VM were ever redeployed as
    // Existing/Managed (the default mode) -- breaking Postgres mid-flight. An absent key leaves any
    // existing attachment untouched.
    storageProfile: union({
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }, databaseMode == 'Local' ? {
      // Local mode: attach the dedicated data disk that holds the PostgreSQL data. It is a separate
      // resource (created empty / never wiped by redeploy), so the DB survives VM recreation.
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          // Detach (not Delete) on VM deletion: the whole point of the separate disk resource is that
          // the database survives `az vm delete` / a recreate. Already Azure's default for an attached
          // pre-existing disk, but stating it makes the durability guarantee ARM-enforced and unchecks
          // the disk in the Portal's "Delete VM" dialog, preventing an accidental data wipe.
          deleteOption: 'Detach'
          managedDisk: { id: localDataDisk!.id }
        }
      ]
    } : {})
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
    // Managed boot diagnostics — REQUIRED for Azure Serial Console, the break-glass path when no
    // SSH key is set (the generated password is only reachable via Serial Console).
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
  // Wait for the app vault (which carries the VM identity's access-policy read grant) + ALL the
  // deploy-time secrets before the VM boots and fetches, so the boot-time KV read never races their
  // creation. (The secrets dependsOn the vault, so its access policy is in place too.) Conditional secrets
  // that aren't deployed (their `if` is false) are silently skipped in dependsOn. (The boot-fetch also retries, and only writes its
  // completion sentinel after every secret lands -- so a missed one fails closed rather than starting
  // broch half-configured.) Managed mode additionally waits for the provisioned DB (broch runs EF
  // migrations against it on boot; the chain pulls in the private DNS link too).
  dependsOn: databaseMode == 'Managed' ? [kvVmPassword, secMasterKey, secDbConn, secAuthSecret, secCloudflare, secAzureDnsSecret, secAwsKeyId, secAwsSecret, secDoToken, postgresDatabase] : [kvVmPassword, secMasterKey, secDbConn, secPgPassword, secAuthSecret, secCloudflare, secAzureDnsSecret, secAwsKeyId, secAwsSecret, secDoToken]
}

// Auto-grant the VM's managed identity "DNS Zone Contributor" on the DNS zone's resource group,
// so Caddy's ACME DNS-01 works with NO manual post-deploy step. Scoped to the RG (Caddy is
// configured with the RG, not a single zone — it finds the zone matching the hostname). Requires
// the deployer to have Owner / User Access Administrator on that RG; if they don't, leave
// dnsZoneResourceGroup empty and grant the role by hand instead. RBAC propagation is eventual —
// Caddy retries issuance until the grant lands.
module dnsRoleAssignment 'dns-role.bicep' = if (azureDnsManagedIdentity && !empty(dnsZoneResourceGroup)) {
  name: 'broch-dns-role'
  scope: resourceGroup(dnsZoneResourceGroup)
  params: {
    principalId: vm.identity!.principalId
  }
}

// Human-readable SSH state for the vmAccess output (extracted to avoid deeply-nested ternaries).
var sshState = empty(sshAllowedCidr) ? 'closed' : 'limited to ${sshAllowedCidr}'
var sshStateWithHint = empty(sshAllowedCidr) ? 'closed (set sshAllowedCidr to open it)' : 'limited to ${sshAllowedCidr}'

// Cold-start expectation for the customer: the ARM deployment reports success several minutes
// before the appliance is reachable (VM boot + image pull + DNS propagation + ACME issuance).
// Surface it as an output so the portal shows it right when the customer is about to hit the URL,
// so the first-boot wait is not misread as a failed deploy.
output readiness string = 'First boot takes ~3-10 minutes: VM provisioning, container pulls, DNS propagation, and Let\'s Encrypt TLS issuance. https://${wildcardHostname} will not load until this finishes -- this is expected, not a failed deploy. The appliance is ready when https://${wildcardHostname}/healthz returns 200.'
output publicIpAddress string = publicIp.properties.ipAddress
output dnsHint string = 'Create A records: ${wildcardHostname} and *.${wildcardHostname} -> ${publicIp.properties.ipAddress} (DNS-only / grey-cloud on Cloudflare)'
output databaseHost string = databaseMode == 'Managed' ? pgHost : (databaseMode == 'Local' ? 'local (PostgreSQL on this VM)' : 'external (you supplied the connection string)')
output keyVaultName string = keyVault.name
output breakGlassKeyVaultName string = usePassword ? bgKvName : ''
output managedIdentityPrincipalId string = vm.?identity.?principalId ?? ''
// The user-assigned identity the app vault's access policy grants secret-read (and that holds AzureDns
// rights). Use THIS to grant the VM identity more permissions; managedIdentityPrincipalId above is the
// system-assigned one, present only in dnsProvider=AzureDns mode.
output vmIdentityPrincipalId string = vmIdentity.properties.principalId
output dnsRoleAssignment string = azureDnsManagedIdentity ? (empty(dnsZoneResourceGroup) ? 'Set dnsZoneResourceGroup to auto-grant, or grant the VM identity "DNS Zone Contributor" on your zone manually.' : 'DNS Zone Contributor granted automatically on resource group "${dnsZoneResourceGroup}".') : '(provider authenticates with a supplied credential; no role assignment)'
output vmAccess string = usePassword ? 'No SSH key set; inbound SSH ${sshState}. Break-glass: Azure Serial Console as "${adminUsername}" (password in Key Vault "${bgKvName}", secret "vm-admin-password"), or `az vm run-command`.' : 'SSH key set for "${adminUsername}"; inbound SSH ${sshStateWithHint}.'
