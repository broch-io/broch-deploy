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

// --- SECRETS FIRST. Parameter order here IS the field order in the portal's Custom-deployment /
// Redeploy form (the raw form renders template params top-to-bottom, shows ALL of them, and has no
// conditional show/hide or conditional-required — the only levers are order, no-default requiredness,
// and description text). A retry of a failed deployment happens through Azure's Redeploy button, whose
// form prefills every NON-secret from the failed attempt and blanks these — so the fields a customer
// must actually act on are grouped at the top instead of buried among thirty prefilled ones. Keep any
// new secret param in this block. ---

@description('REQUIRED — on every deploy AND every retry of a failed deployment (no default, so the portal Redeploy form and ARM validation both refuse an empty submission; that fail-fast is deliberate). The at-rest encryption root (BROCH_MASTER_KEY) — customer-owned, Broch never sees it. Generate a strong value with `openssl rand -base64 48` and store it in your own secret store; the SAME value must be supplied on every (re)deploy. For an Existing database this MUST be the key that database was encrypted with — a different key cannot decrypt its Data Protection keyring (recoverable: users re-auth and the license re-activates, but disruptive). The server also rejects values under 32 bytes at boot.')
@minLength(32)
@secure()
param brochMasterKey string

@description('REQUIRED whenever authProvider is set — on a FIRST deployment (the form cannot enforce this; leaving it empty then makes the appliance halt at the boot-time secret fetch, fail-closed). OIDC client secret the server uses to exchange authorization codes. On a Redeploy retry it may be left blank: the value stored by the failed attempt is reused; supply a value only to overwrite it.')
@secure()
param authClientSecret string = ''

@description('REQUIRED when dnsProvider=Cloudflare and certMode=Auto — on a FIRST deployment (the form cannot enforce this; leaving it empty then makes the appliance halt at the boot-time secret fetch, fail-closed). Cloudflare API token (Zone:Read + DNS:Edit). On a Redeploy retry it may be left blank: the stored value is reused.')
@secure()
param cloudflareApiToken string = ''

@description('REQUIRED when dnsProvider=AzureDnsServicePrincipal and certMode=Auto — on a FIRST deployment (fail-closed at the boot-time fetch if omitted). Service-principal client secret. On a Redeploy retry it may be left blank: the stored value is reused.')
@secure()
param azureClientSecret string = ''

@description('REQUIRED when dnsProvider=Route53 and certMode=Auto — on a FIRST deployment (fail-closed at the boot-time fetch if omitted). AWS access key ID for a principal with Route 53 list+change rights on the zone. On a Redeploy retry it may be left blank: the stored value is reused.')
@secure()
param awsAccessKeyId string = ''

@description('REQUIRED when dnsProvider=Route53 and certMode=Auto (same behaviour as awsAccessKeyId). AWS secret access key. On a Redeploy retry it may be left blank: the stored value is reused.')
@secure()
param awsSecretAccessKey string = ''

@description('REQUIRED when dnsProvider=DigitalOcean and certMode=Auto (same behaviour as the other DNS credentials). DigitalOcean API token with DNS write scope. On a Redeploy retry it may be left blank: the stored value is reused.')
@secure()
param doAuthToken string = ''

@description('REQUIRED when databaseMode=Managed — on a FIRST deployment. Admin password for the provisioned PostgreSQL (8-128 chars; at least 3 of lower/upper/digit/symbol). On a Redeploy retry it may be left blank: the deployment reads the value the failed attempt stored in the Key Vault and applies it to the database server. Supply a value only to set or rotate the password.')
@secure()
param postgresAdminPassword string = ''

@description('REQUIRED when databaseMode=Existing — on a FIRST deployment. Npgsql connection string for your existing PostgreSQL. On a Redeploy retry it may be left blank: the stored value is reused. Ignored when databaseMode=Managed/Local.')
@secure()
param databaseConnectionString string = ''

@description('Optional password for the bundled Local PostgreSQL (databaseMode=Local). Leave empty for a zero-config default DERIVED from the resource group + VM name. That default is computable by anyone with Reader on the subscription, so SET an explicit value for any deployment where the VM identity could be compromised (Postgres has no host port, so the practical blast radius is limited to in-container code execution). If you set one, STORE IT and re-supply the SAME value on every (re)deploy of the VM (Postgres keeps the password from when its data dir was first initialised). Ignored for Existing/Managed.')
@secure()
param localDbAdminPassword string = ''

@description('REQUIRED when dnsProvider=GoogleCloudDns and certMode=Auto. Base64-encoded GCP service-account JSON key (roles/dns.admin on the zone). Re-enter on a Redeploy retry (delivered via customData, not the vault — a blank retry is NOT reused).')
@secure()
param gcpCredentialsJson string = ''

@description('REQUIRED when certMode=Byo. Base64-encoded PEM fullchain (cert + intermediates) covering the apex + wildcard. Re-enter on a Redeploy retry (delivered via customData, not the vault).')
@secure()
param tlsCertificate string = ''

@description('REQUIRED when certMode=Byo. Base64-encoded PEM private key for the wildcard cert. Re-enter on a Redeploy retry (delivered via customData, not the vault).')
@secure()
param tlsCertificateKey string = ''

@description('Registry token/password. Empty (default) = the image is public, no login. Set this (only this) to pull a private pre-release/beta image — the server/username already default to GHCR. Re-enter on a Redeploy retry if set.')
@secure()
param registryPassword string = ''

@description('Exact names of soft-deleted Key Vaults present in the subscription — supplied so this deployment can RECOVER any whose name collides with a vault it is about to create. Only relevant when redeploying into a RECREATED resource group (same name + region as a deleted Broch deployment): deleting a group soft-deletes its Key Vaults for 7 days, and the recreated group re-derives the SAME vault names, so a plain create fails with "A vault with the same name already exists in deleted state". This template recovers a vault ONLY when its exact computed name appears in this list — a supplied name that does not match any vault this deployment creates is ignored (no-op), and a name created by an OLDER template version (different salt/scheme) simply is not matched, so the fresh differently-named vault is created clean instead of the deploy hard-failing. The marketplace wizard fills this automatically from a live probe of the subscription\'s soft-deleted vaults matching this group + region; raw-form deployers read the exact name(s) from the "already exists in deleted state" error and list them here. Leave empty (the default) for every first-time deploy and for a group that never hosted Broch. Recovery is same-region only — cross-region recreation derives fresh names and needs no entry here.')
param softDeletedVaultNames array = []

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

@description('DNS zone you own, e.g. example.com — the parent domain Broch builds tunnel URLs under. This is the ZONE ONLY, not the full tunnel host: put the tunnel label in shareSubdomain below (dnsZone=example.com + shareSubdomain=broch), NOT dnsZone=broch.example.com. You must control this zone at a supported DNS provider (see README). Combined with shareSubdomain, it fixes the public hostname: Broch serves <shareSubdomain>.<dnsZone> and *.<shareSubdomain>.<dnsZone>.')
@minLength(1)
param dnsZone string

@description('Subdomain of dnsZone that hosts the public tunnel URLs. Default "broch" → Broch serves broch.<dnsZone> and *.broch.<dnsZone>. Leave EMPTY to serve tunnels at the zone apex itself (<dnsZone> and *.<dnsZone>). Usually a single label; a dotted value (e.g. "a.b") is accepted for a deeper subdomain.')
param shareSubdomain string = 'broch'

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

@description('Resource group of the Azure DNS zone — dnsProvider=AzureDns or AzureDnsServicePrincipal (zone in this deployment\'s subscription).')
param dnsZoneResourceGroup string = ''

@description('Azure AD tenant ID of the service principal — dnsProvider=AzureDnsServicePrincipal.')
param azureTenantId string = ''

@description('Service-principal (app registration) client ID, pre-granted DNS Zone Contributor on the zone — dnsProvider=AzureDnsServicePrincipal.')
param azureClientId string = ''

@description('GCP project ID hosting the Cloud DNS zone — dnsProvider=GoogleCloudDns.')
param gcpProject string = ''

@description('Broch server image tag. Defaults to a concrete pinned version (NOT latest) so a redeploy never silently rolls the box across an EF-migration boundary; new releases of this template bump this default. Redeploying an existing installation? Enter the version it currently runs — the Deployments history of the resource group shows it, and the Redeploy button on the prior deployment pre-fills it — because a newer version migrates the database irreversibly. Set a newer tag to upgrade deliberately, or "latest" to float. 1.29.0+ is required for dnsAutoRecords=Auto (it serves /internal/public-ip, which caddy-dynamicdns polls to write the A records).')
param brochVersion string = '1.31.0'

@description('Broch server image repository (no tag). Default is the public image. Override for a private mirror or a pre-release/beta image you have been granted access to — set the registry* params below for the pull credential.')
param brochImage string = 'ghcr.io/broch-io/broch'

@description('Container registry host — defaults to ghcr.io (where Broch images live). Only used when registryPassword is set.')
param registryServer string = 'ghcr.io'

@description('Registry login username — defaults to a value GHCR accepts with a valid token. Only used when registryPassword is set.')
param registryUsername string = 'broch'

@description('CIDR allowed to reach SSH (port 22). Empty (default) creates NO inbound SSH rule — the box is managed via `az vm run-command` / Azure Serial Console, the secure default. Set a CIDR (e.g. your admin network) to allow SSH break-glass.')
param sshAllowedCidr string = ''

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

@description('Size (GiB) of the dedicated data disk attached in every database mode. It persists Docker volume state across VM reboots and recreation: the TLS certificate store always (so a recreate re-uses the issued certificate instead of burning Let\'s Encrypt\'s issuance rate limit), and the Local PostgreSQL data when databaseMode=Local. Broch\'s database is tiny; the default suits typical use — size up only if you retain large audit/request-log history. Pick the size at first deploy: INCREASING it on a later redeploy resizes the Azure disk but does NOT auto-grow the ext4 filesystem — run `sudo resize2fs /dev/disk/azure/scsi1/lun0` on the VM afterward (and note some disk tiers require a VM deallocate to resize). Shrinking is not supported.')
@minValue(4)
@maxValue(1024)
param dataDiskSizeGb int = 4

@allowed([
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_D2ds_v5'
  'Standard_D4ds_v5'
])
@description('Compute size for the provisioned PostgreSQL (Managed mode).')
param postgresSkuName string = 'Standard_B1ms'

// --- Identity provider (boot floor). Set what your provider needs; leave the rest ''. The client
// SECRET lives in the secrets block at the top (form-order); setting authProvider without it fails
// closed at the boot-fetch — secretless/public-client OIDC is not supported via this template. ---
@description('Auth0 | AzureAd | EntraExternalId | Okta | Oidc')
param authProvider string = ''
param authClientId string = ''
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
// The name carries the SAME deterministic salt as the Key Vaults (kvId, below): flexible-server
// names are GLOBAL — the server owns <name>.postgres.database.azure.com even in private-access
// mode (the private DNS zone only changes how it resolves inside the VNet, not the reservation).
// A bare '<vmName>-pg' means the first Managed-mode deployment anywhere claims the name and every
// later one dies late with ServerNameAlreadyExists; the salt keeps redeploys of the SAME
// RG+region converging on the same server while making every other deployment distinct.
var pgServerName = '${vmName}-pg-${kvId}'
var pgAdminUser = 'brochadmin'
var pgDatabaseName = 'brochdb'
// The private DNS zone is required for VNet injection but must NOT be used to build the
// connection Host: Azure registers the zone's A record under an instance-specific label, not
// under <serverName>, so '<serverName>.<zone>' does not resolve. The name that resolves inside
// the VNet is the server's real FQDN, <serverName>.postgres.database.azure.com — Azure DNS
// aliases it to the zone record.
var pgDnsZone = '${vmName}-db.private.postgres.database.azure.com'
var pgHost = '${pgServerName}.postgres.database.azure.com'
// The Managed-mode connection string is NOT composed here: pg.bicep writes db-connection-string from
// the SAME getSecret-resolved password that configures the server (one source — the pair cannot be
// written from different values; see the module header). The parent writes it only for Existing mode.

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

// The master key is always customer-supplied (required + @minLength) — never generated — so a
// (re)deploy can't mint a different key that fails to decrypt an existing database, and a retry
// re-supplies it (same value, per the stored-key contract).
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
  // Drives the cloud-init DB-connection-string gate: Local skips the connstring requirement (the
  // bundled Postgres needs none). The data-disk mount is UNCONDITIONAL in cloud-init (the disk is
  // attached in every mode) and no longer reads this token.
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
  // Vault DNS suffix from environment() (leading dot included, e.g. sovereign clouds differ) —
  // substituted so the compiled template carries no literal vault host (arm-ttk: DeploymentTemplate
  // Must Not Contain Hardcoded Uri; Partner Center certification enforces it).
  ['__KV_DNS_SUFFIX__', environment().suffixes.keyvaultDns]
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

// The server itself lives in pg.bicep so its admin password can come from kv.getSecret() — a Key
// Vault reference ARM resolves at deployment time (only module @secure() params accept it). First
// deploy: the supplied postgresAdminPassword is written to the vault (secPgAdminPassword) and read
// straight back here. Redeploy retry with a BLANK password: the write is skipped (blank never
// overwrites) and getSecret returns the FIRST attempt's value — so a retry needs only the master
// key, and the server's password stays consistent with the stored db-connection-string. A blank
// password with NO stored secret (misused first deploy) fails LOUDLY at deployment time — getSecret
// on a missing secret is an ARM error, not a boot-time brick. Requires enabledForTemplateDeployment
// on the vault (see the keyVault resource).
resource kvForPgSecret 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: kvName
}

module postgresServer 'pg.bicep' = if (databaseMode == 'Managed') {
  name: 'broch-pg-server'
  params: {
    location: location
    kvName: kvName
    pgServerName: pgServerName
    pgAdminUser: pgAdminUser
    pgDatabaseName: pgDatabaseName
    postgresSkuName: postgresSkuName
    administratorLoginPassword: kvForPgSecret.getSecret('pg-admin-password')
    delegatedSubnetResourceId: vnet.properties.subnets[1].id
    privateDnsZoneArmResourceId: postgresDnsZone.id
  }
  // keyVault: the vault (and its enabledForTemplateDeployment) must exist before the nested
  // deployment resolves the secret reference; secPgAdminPassword: a supplied password must land
  // before it is read back (skipped-when-blank is a legal dependsOn).
  dependsOn: [ postgresDnsLink, keyVault, secPgAdminPassword ]
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
// uniqueString(rg.id, vmName, location) is DETERMINISTIC: the same deployment always recomputes the same
// names, so a redeploy re-targets the same vaults (no churn); a different RG/subscription/region gets
// distinct ones. The LOCATION salt is deliberate: a soft-deleted vault reserves its global
// name for 7 days across ALL regions but is recoverable only in its own region. Without the salt, a
// same-name RG recreated in a DIFFERENT region derived the ghost's exact names and failed with
// VaultAlreadyExists — unfixable except by purge/wait. With it, cross-region recreation derives fresh
// names (clean create, ghosts expire harmlessly) while the one recoverable case — same RG name, same
// region — still re-derives identical names, so the recover pre-pass matches the ghost and targets the
// right vaults. These names are also distinct from the old single-vault template's <vmName>-kv-<hash>, so on an
// UPGRADE the app vault is created DIRECTLY in access-policy mode -- never an RBAC->access-policy flip,
// which would need Owner/UAA and break Contributor-deployability. Length <= 24: take(vmName,12) + '-app-'
// (5) + id (7) = 24.
// The Azure Marketplace offer's create wizard probes soft-deleted vaults by these literal prefixes
// (with the default vmName) and passes the EXACT matching names as softDeletedVaultNames, which this
// template intersects with the names below to decide what to recover. Changing the vmName default, the
// '-app-'/'-bg-' infixes, or this derivation only means a ghost from the old scheme no longer matches
// the new name — so it is left to expire and the fresh vault is created clean, never a hard failure.
var kvId = take(uniqueString(resourceGroup().id, vmName, location), 7)
var kvBaseName = take(vmName, 12)
var kvName = '${kvBaseName}-app-${kvId}'
var bgKvName = '${kvBaseName}-bg-${kvId}'

// Recover a vault ONLY when its EXACT name is among the soft-deleted names supplied (the wizard's live
// probe, or a raw-form list). Intersecting on the exact computed name — NOT a prefix — is what makes a
// template-version name change safe: a ghost left by an older salt/naming scheme is simply not matched,
// so the createMode:'recover' pre-pass is skipped for it and the fresh (differently-named) vault is
// created clean, instead of the deploy hard-failing on a recover PUT against a name that exists in no
// state. bgKvName is only ever created in password mode, so gate its recovery on usePassword too.
var recoverAppVault = contains(softDeletedVaultNames, kvName)
var recoverBgVault = usePassword && contains(softDeletedVaultNames, bgKvName)

// User-assigned managed identity the VM uses to (a) read the deploy-time secrets from Key Vault at boot
// and (b) complete Caddy's AzureDns ACME challenge (dnsProvider=AzureDns). User-assigned, NOT
// system-assigned, on purpose: its principalId exists BEFORE the VM, so the app vault's access policy
// (below) names it and is in place the instant the vault is created -- cloud-init's boot-time secret
// fetch then does not race grant propagation. Declared ahead of the vault so the vault can reference it.
resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${vmName}-id'
  location: location
}

// Opt-in soft-delete recovery pre-pass for a RECREATED same-name resource group (see the param and
// kv-recover.bicep for the mechanism). Runs BEFORE the vault resources below, which then apply the
// full desired state — the fresh VM identity's access policy, enabledForTemplateDeployment, flags —
// as a normal update over the recovered vaults.
module kvRecover 'kv-recover.bicep' = if (recoverAppVault || recoverBgVault) {
  name: 'broch-kv-recover'
  params: {
    location: location
    kvName: kvName
    bgKvName: bgKvName
    // Each vault is recovered only if its exact name was supplied as soft-deleted (see the derivation
    // above). This also covers the SSH-key-then-password auth-mode flip: no bg ghost exists, its name
    // is not in the list, recoverBg stays false, and its recover PUT never runs.
    recoverApp: recoverAppVault
    recoverBg: recoverBgVault
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  dependsOn: [ kvRecover ]
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
    // Lets THIS template read pg-admin-password back via getSecret() (the pg module), so a Redeploy
    // retry can leave the password blank. Trust surface: principals with Microsoft.KeyVault/vaults/
    // deploy/action (in Contributor) can reference these secrets from their own deployments — the
    // same class as the accessPolicies/write tradeoff above (an RG Contributor is already inside
    // this boundary via run-command), accepted for the same reason.
    enabledForTemplateDeployment: true
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
  dependsOn: [ kvRecover ]
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Rewritten on EVERY deploy (vmPasswordSeed is newGuid() per run). On a retry over an EXISTING VM,
// Azure ignores the adminPassword change, so the vault copy rotates away from the VM's real password —
// the documented "rotates on every redeploy" wart (README); re-read it from the vault, or reset with
// `az vm user update` if Serial Console break-glass is ever needed on such a box.
resource kvVmPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (usePassword) {
  parent: bgKeyVault
  name: 'vm-admin-password'
  properties: { value: generatedVmPassword }
}

// Deploy-time secrets the VM fetches at boot (kept OUT of customData). Every deploy AND every retry
// re-supplies them (brochMasterKey is ARM-required; the rest are enforced by the wizard on first
// deploys and fail closed at the boot-fetch if omitted on a raw Redeploy-form retry — see kvSecretMap).
resource secMasterKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'broch-master-key'
  properties: { value: brochMasterKey }
}
// Existing mode only — Managed mode's db-connection-string is written by pg.bicep from the
// getSecret-resolved password (one source with the server's own password; see the module header).
resource secDbConn 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (databaseMode == 'Existing' && !empty(databaseConnectionString)) {
  parent: keyVault
  name: 'db-connection-string'
  properties: { value: databaseConnectionString }
}
// The Managed admin password lands in the vault standalone so the pg module can read it back via
// getSecret() on a blank-password retry. The module then composes db-connection-string from that
// SAME resolved value (see pg.bicep) — the standalone password and the one inside the connection
// string share one source and cannot be written from different values.
resource secPgAdminPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (databaseMode == 'Managed' && !empty(postgresAdminPassword)) {
  parent: keyVault
  name: 'pg-admin-password'
  properties: { value: postgresAdminPassword }
}
resource secPgPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (databaseMode == 'Local') {
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

// Boot-fetch map: ENVKEY=secret-name pairs, ';'-joined. cloud-init splits this, fetches each from Key
// Vault via the VM identity, and appends KEY=value to /opt/broch/.env. The list is a PURE FUNCTION OF
// THE SELECTIONS (databaseMode / certMode / dnsProvider / authProvider) — deliberately NOT of which
// secret params were supplied — for two load-bearing reasons:
// 1. customData is identical across every same-selection attempt, and Azure REJECTS a customData
//    change on an existing VM (PropertyChangeNotAllowed). A param-driven list would bake a DIFFERENT
//    fetch list into the VM whenever a retry's supplied-param set differed from the first attempt's —
//    leaving a VM that no corrected redeploy can ever fix (only deletion recovers it).
// 2. Fail closed over half-deployed: the raw Redeploy form cannot make a DNS credential conditionally
//    required, so an omitted-but-selected secret must brick the boot (fetch halts on the missing vault
//    secret; broch.service is never enabled) rather than come up without TLS/login and look healthy.
// Corollary (documented in the param block + README): authProvider set with no client secret —
// secretless/public-client OIDC — fails closed too, and is unsupported via this template.
var kvSecretMap = join(filter([
  'BROCH_MASTER_KEY=broch-master-key'
  databaseMode == 'Local' ? 'POSTGRES_PASSWORD=postgres-password' : 'BROCH_DB_CONNECTION_STRING=db-connection-string'
  empty(authProvider) ? '' : 'AUTHENTICATION__CLIENTSECRET=auth-client-secret'
  certMode == 'Auto' && dnsProvider == 'Cloudflare' ? 'CLOUDFLARE_API_TOKEN=cloudflare-api-token' : ''
  certMode == 'Auto' && dnsProvider == 'AzureDnsServicePrincipal' ? 'AZURE_DNS_CLIENT_SECRET=azure-dns-client-secret' : ''
  certMode == 'Auto' && dnsProvider == 'Route53' ? 'AWS_ACCESS_KEY_ID=aws-access-key-id' : ''
  certMode == 'Auto' && dnsProvider == 'Route53' ? 'AWS_SECRET_ACCESS_KEY=aws-secret-access-key' : ''
  certMode == 'Auto' && dnsProvider == 'DigitalOcean' ? 'DO_AUTH_TOKEN=do-auth-token' : ''
], item => !empty(item)), ';')

// Dedicated data disk, attached in EVERY database mode. A SEPARATE resource so state survives VM
// recreation: createOption Empty is create-once (a redeploy never wipes it), and the VM attaches
// it. It backs /var/lib/docker/volumes, which holds ALL Docker named volumes: Caddy's cert/ACME
// store (caddy_data) in every mode — so a VM recreate re-uses the issued certificate instead of
// re-requesting from Let's Encrypt production (~5 duplicate certs/week/hostname; repeated
// recreates without this disk hit that limit and lock TLS issuance out for up to a week) — plus
// the bundled Postgres data dir in Local mode. Standard SSD is plenty for both.
resource dataDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: '${vmName}-data'
  location: location
  sku: { name: 'StandardSSD_LRS' }
  properties: {
    creationData: { createOption: 'Empty' }
    diskSizeGB: dataDiskSizeGb
    // The disk holds the TLS private keys (Caddy cert store) and, in Local mode, the bundled
    // Postgres data dir (pg_wal + all user state). Block the SAS-export path so a Contributor on
    // the RG can't `az disk grant-access` to download the raw ext4 image out-of-band — the data is
    // reachable only through the VM. publicNetworkAccess=Disabled is belt-and-suspenders (DenyAll
    // already covers it) and makes the hardened intent explicit.
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
    storageProfile: {
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
      // Attach the dedicated data disk in EVERY mode (it backs /var/lib/docker/volumes: the Caddy
      // cert store always, plus the Local-mode Postgres data). It is a separate resource (created
      // empty / never wiped by redeploy), so that state survives VM recreation. Declaring the
      // attachment unconditionally also means a redeploy in a DIFFERENT database mode can never
      // present a dataDisks:[] desired state that would detach the disk mid-flight.
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          // Detach (not Delete) on VM deletion: the whole point of the separate disk resource is that
          // the data survives `az vm delete` / a recreate. Already Azure's default for an attached
          // pre-existing disk, but stating it makes the durability guarantee ARM-enforced and unchecks
          // the disk in the Portal's "Delete VM" dialog, preventing an accidental data wipe.
          deleteOption: 'Detach'
          managedDisk: { id: dataDisk.id }
        }
      ]
    }
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
  dependsOn: databaseMode == 'Managed' ? [kvVmPassword, secMasterKey, secAuthSecret, secCloudflare, secAzureDnsSecret, secAwsKeyId, secAwsSecret, secDoToken, postgresServer] : [kvVmPassword, secMasterKey, secDbConn, secPgPassword, secAuthSecret, secCloudflare, secAzureDnsSecret, secAwsKeyId, secAwsSecret, secDoToken]
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
