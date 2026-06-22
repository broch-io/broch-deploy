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

@description('Optional. AAD object ID of a user/group to grant Key Vault Secrets User on the created Key Vault, so you can read the generated break-glass VM password without a manual role grant. Empty (default) grants no data-plane access — grant yourself later. (The master key is never stored in the vault — it is customer-supplied.)')
param adminObjectId string = ''

@description('Principal type of adminObjectId — set Group if it is an AAD group, or ServicePrincipal for a CI/CD managed identity / service principal. Lets ARM skip a type lookup that can race AAD replication and fail the role assignment.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param adminObjectType string = 'User'

@description('Wildcard hostname for tunnels + API, e.g. tunnels.example.com. You must own this domain and point its DNS at this VM (see README).')
param wildcardHostname string

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

@description('Broch server image tag. Pin in production.')
param brochVersion string = 'latest'

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

@description('REQUIRED. The at-rest encryption root (BROCH_MASTER_KEY) — customer-owned, Broch never sees it. Generate a strong value with `openssl rand -base64 48` and store it in your own secret store; the SAME value must be supplied on every (re)deploy. For an Existing database this MUST be the key that database was encrypted with — a different key cannot decrypt its Data Protection keyring (recoverable: users re-auth and the license re-activates, but disruptive). The server also rejects values under 32 bytes at boot.')
@minLength(32)
@secure()
param brochMasterKey string

@description('Internal — do not set. Entropy for the generated break-glass VM password (used only when no SSH key is supplied).')
@secure()
param vmPasswordSeed string = newGuid()

// --- Database. Existing = connect to your own PostgreSQL; Managed = provision an Azure
// Database for PostgreSQL Flexible Server in this deployment (the marketplace one-click). ---
@allowed([
  'Existing'
  'Managed'
])
@description('Existing: connect to the PostgreSQL you supply in databaseConnectionString. Managed: provision an Azure PostgreSQL Flexible Server in this deployment.')
param databaseMode string = 'Existing'

@description('Npgsql connection string for your existing PostgreSQL (Existing mode). Ignored when databaseMode=Managed.')
@secure()
param databaseConnectionString string = ''

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
// the deterministic private-DNS FQDN (no resource reference, so it stays valid when Managed
// is off). The private DNS zone is named to match, so the VM resolves it inside the VNet.
var pgServerName = '${vmName}-pg'
var pgAdminUser = 'brochadmin'
var pgDatabaseName = 'brochdb'
// The private DNS zone is named independently of the server. A VNet-integrated Flex Server
// registers an A record for <serverName> INSIDE the zone, so the resolvable FQDN is
// <serverName>.<zone> — the connection Host must include the server label.
var pgDnsZone = '${vmName}-db.private.postgres.database.azure.com'
var pgHost = '${pgServerName}.${pgDnsZone}'
var managedConnectionString = 'Host=${pgHost};Port=5432;Database=${pgDatabaseName};Username=${pgAdminUser};Password=${postgresAdminPassword};SSL Mode=Require'
var effectiveConnectionString = databaseMode == 'Managed' ? managedConnectionString : databaseConnectionString

// The master key is always customer-supplied (required + @minLength) — never generated. So a
// (re)deploy can't mint a different key that fails to decrypt an existing database.
// No SSH key supplied => provision a generated break-glass password (Serial Console).
// Azure complexity needs >=3 of upper/lower/digit/special. The GUID seed always supplies
// lowercase/digit plus hyphens (which Azure counts as special); appending an uppercase letter
// and a digit guarantees the third class — without a password-shaped literal that trips
// secret scanners (the entropy is the GUID, not the suffix).
var usePassword = empty(adminSshPublicKey)
var generatedVmPassword = '${vmPasswordSeed}X9'
// The Key Vault now exists only to hold the generated break-glass password — so a deploy that
// brings its own SSH key (e.g. prod) creates no Key Vault and no new resources.
var needsKeyVault = usePassword

// --- TLS config selection ---
// Auto mode: build the tls.caddy fragment the Caddyfile imports, per DNS provider. All provider
// modules are compiled into the broch-caddy image (see Caddy.Dockerfile), so this is just config.
// Byo mode: the BYO-cert Caddyfile (:443 catch-all) reads the supplied cert from /etc/caddy/certs;
// tls.caddy is unused. Caddyfiles come from broch-deploy (single source).
// Azure managed identity = omit tenant/client/secret; service principal = include them.
var tlsCloudflare = 'tls {\n\tdns cloudflare {env.CLOUDFLARE_API_TOKEN}\n}\n'
var tlsAzureMi = 'tls {\n\tdns azure {\n\t\tsubscription_id {env.AZURE_DNS_SUBSCRIPTION_ID}\n\t\tresource_group_name {env.AZURE_DNS_RESOURCE_GROUP}\n\t}\n}\n'
var tlsAzureSpn = 'tls {\n\tdns azure {\n\t\tsubscription_id {env.AZURE_DNS_SUBSCRIPTION_ID}\n\t\tresource_group_name {env.AZURE_DNS_RESOURCE_GROUP}\n\t\ttenant_id {env.AZURE_DNS_TENANT_ID}\n\t\tclient_id {env.AZURE_DNS_CLIENT_ID}\n\t\tclient_secret {env.AZURE_DNS_CLIENT_SECRET}\n\t}\n}\n'
var tlsRoute53 = 'tls {\n\tdns route53 {\n\t\taccess_key_id {env.AWS_ACCESS_KEY_ID}\n\t\tsecret_access_key {env.AWS_SECRET_ACCESS_KEY}\n\t}\n}\n'
var tlsGoogle = 'tls {\n\tdns googleclouddns {\n\t\tgcp_project {env.GCP_PROJECT}\n\t}\n}\n'
var tlsDigitalOcean = 'tls {\n\tdns digitalocean {env.DO_AUTH_TOKEN}\n}\n'
var autoTlsCaddy = dnsProvider == 'Cloudflare' ? tlsCloudflare : (dnsProvider == 'AzureDns' ? tlsAzureMi : (dnsProvider == 'AzureDnsServicePrincipal' ? tlsAzureSpn : (dnsProvider == 'Route53' ? tlsRoute53 : (dnsProvider == 'GoogleCloudDns' ? tlsGoogle : tlsDigitalOcean))))
var tlsCaddyContent = certMode == 'Byo' ? '# BYO-cert mode: TLS is set in the Caddyfile; this fragment is unused.\n' : autoTlsCaddy
var caddyfileContent = certMode == 'Byo' ? loadTextContent('../../docker-compose/with-postgres-byo-cert/Caddyfile') : loadTextContent('../../docker-compose/with-postgres-external/Caddyfile')

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
  // Canonical compose stack, embedded VERBATIM (base64) from the shared
  // docker-compose/with-postgres-external template — single source of truth, so the
  // VM runs the same bytes as a docker-direct customer and the two cannot drift.
  ['__COMPOSE_B64__', base64(loadTextContent('../../docker-compose/with-postgres-external/docker-compose.yml'))]
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
  ['__BROCH_MASTER_KEY__', brochMasterKey]
  ['__WILDCARD_HOSTNAME__', wildcardHostname]
  ['__CADDY_ACME_EMAIL__', acmeEmail]
  ['__CLOUDFLARE_API_TOKEN__', cloudflareApiToken]
  // The __AZURE_*__ token names are intentionally NOT renamed — they are internal
  // substitution placeholders. The .env var NAMES they populate were renamed to
  // AZURE_DNS_* in cloud-init.yaml; "correcting" this apparent mismatch breaks substitution.
  ['__AZURE_SUBSCRIPTION_ID__', azureSubscriptionId]
  ['__AZURE_DNS_RESOURCE_GROUP__', dnsZoneResourceGroup]
  ['__AZURE_TENANT_ID__', azureTenantId]
  ['__AZURE_CLIENT_ID__', azureClientId]
  ['__AZURE_CLIENT_SECRET__', azureClientSecret]
  ['__AWS_ACCESS_KEY_ID__', awsAccessKeyId]
  ['__AWS_SECRET_ACCESS_KEY__', awsSecretAccessKey]
  ['__DO_AUTH_TOKEN__', doAuthToken]
  ['__GCP_PROJECT__', gcpProject]
  ['__GOOGLE_APP_CREDS_PATH__', gcpCredsPath]
  // 'e30=' (base64 of '{}') when no GCP creds: an empty value renders `content: ` in the
  // cloud-init write_files entry, which YAML parses as null and can TypeError the whole
  // write_files step (no .env written → unconfigured VM). A valid-but-empty JSON keeps the
  // file parseable; Caddy only reads it in GoogleCloudDns mode, so it's inert otherwise.
  ['__GCP_SA_JSON_B64__', empty(gcpCredentialsJson) ? 'e30=' : gcpCredentialsJson]
  ['__DATABASE_CONNECTION_STRING__', effectiveConnectionString]
  ['__AUTH_PROVIDER__', authProvider]
  ['__AUTH_CLIENT_ID__', authClientId]
  ['__AUTH_CLIENT_SECRET__', authClientSecret]
  ['__AUTH_ADMIN_ROLES__', authAdminRoles]
  ['__AUTH_DOMAIN__', authDomain]
  ['__AUTH_TENANT_ID__', authTenantId]
  ['__AUTH_INSTANCE__', authInstance]
  ['__AUTH_AUTHORITY__', authAuthority]
  ['__AUTH_AUDIENCE__', authAudience]
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

// --- Customer-owned secret store. Created ONLY when a break-glass VM password is generated
// (i.e. no SSH key supplied) — a deploy that brings its own SSH key (e.g. prod) creates none of
// this. RBAC mode; this deployment writes the secret via the control plane (the deployer's
// Contributor on the vault). To READ it, grant yourself — or set adminObjectId — the "Key Vault
// Secrets User" role. The master key is never stored here (it's customer-supplied). ---
// Anchor the unique hash at a fixed offset rather than take()-ing the whole string: a blind
// take(..., 24) drops the hash entirely for vmName >= 20 chars (KV names are GLOBALLY unique,
// so two long same-named deployments would collide) and can leave a trailing '-' (invalid).
// 10 (name) + 4 ('-kv-') + 9 (hash) = 23 <= 24, always alphanumeric-terminated and unique.
var kvName = '${take(vmName, 10)}-kv-${take(uniqueString(resourceGroup().id, vmName), 9)}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (needsKeyVault) {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource kvVmPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (usePassword) {
  parent: keyVault
  name: 'vm-admin-password'
  properties: { value: generatedVmPassword }
}

// Optional: let the deployer read the secrets (Key Vault Secrets User).
resource kvReadGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminObjectId) && needsKeyVault) {
  scope: keyVault
  name: guid(keyVault.id, adminObjectId, 'kv-secrets-user')
  properties: {
    principalId: adminObjectId
    principalType: adminObjectType
    // Key Vault Secrets User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  // Azure-DNS managed-identity mode uses the VM's identity (the template auto-grants it the DNS
  // role below). The service-principal mode and every other provider authenticate with a supplied
  // credential, so no identity is attached.
  identity: azureDnsManagedIdentity ? { type: 'SystemAssigned' } : null
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
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
    // Managed boot diagnostics — REQUIRED for Azure Serial Console, the break-glass path when no
    // SSH key is set (the generated password is only reachable via Serial Console).
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
  // Managed mode: broch runs EF migrations against the provisioned DB on boot, so wait for
  // the server + database (and, via the chain, the private DNS link) to exist first.
  dependsOn: databaseMode == 'Managed' ? [postgresDatabase] : []
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

output publicIpAddress string = publicIp.properties.ipAddress
output dnsHint string = 'Create A records: ${wildcardHostname} and *.${wildcardHostname} -> ${publicIp.properties.ipAddress} (DNS-only / grey-cloud on Cloudflare)'
output databaseHost string = databaseMode == 'Managed' ? pgHost : 'external (you supplied the connection string)'
output keyVaultName string = keyVault.?name ?? ''
output managedIdentityPrincipalId string = vm.?identity.?principalId ?? ''
output dnsRoleAssignment string = azureDnsManagedIdentity ? (empty(dnsZoneResourceGroup) ? 'Set dnsZoneResourceGroup to auto-grant, or grant the VM identity "DNS Zone Contributor" on your zone manually.' : 'DNS Zone Contributor granted automatically on resource group "${dnsZoneResourceGroup}".') : '(provider authenticates with a supplied credential; no role assignment)'
output vmAccess string = usePassword ? 'No SSH key set; inbound SSH ${sshState}. Break-glass: Azure Serial Console as "${adminUsername}" (password in Key Vault secret "vm-admin-password"), or `az vm run-command`.' : 'SSH key set for "${adminUsername}"; inbound SSH ${sshStateWithHint}.'
