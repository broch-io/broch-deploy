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

@description('Optional. AAD object ID of a user/group to grant read access (Key Vault Secrets User) on the created Key Vault, so you can retrieve the generated master key / break-glass password. Empty (default) grants no data-plane access — grant yourself later.')
param adminObjectId string = ''

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
])
@description('DNS-01 provider when certMode=Auto. AzureDns uses the VM\'s managed identity (no secret) — grant it DNS Zone Contributor on the zone after deploy.')
param dnsProvider string = 'Cloudflare'

@description('Email Let\'s Encrypt notifies about cert-renewal failures (certMode=Auto).')
param acmeEmail string = ''

@description('Cloudflare API token (Zone:Read + DNS:Edit) — certMode=Auto + dnsProvider=Cloudflare.')
@secure()
param cloudflareApiToken string = ''

@description('Resource group of the Azure DNS zone — certMode=Auto + dnsProvider=AzureDns (zone in this deployment\'s subscription).')
param dnsZoneResourceGroup string = ''

@description('Base64-encoded PEM fullchain (cert + intermediates) covering the apex + wildcard — certMode=Byo.')
@secure()
param tlsCertificate string = ''

@description('Base64-encoded PEM private key for the wildcard cert — certMode=Byo.')
@secure()
param tlsCertificateKey string = ''

@description('Broch server image tag. Pin in production.')
param brochVersion string = 'latest'

@description('CIDR allowed to reach SSH (port 22). Empty (default) creates NO inbound SSH rule — the box is managed via `az vm run-command` / Azure Serial Console, the secure default. Set a CIDR (e.g. your admin network) to allow SSH break-glass.')
param sshAllowedCidr string = ''

@description('Optional. The EXISTING Broch master key the target database was encrypted with — REQUIRED when pointing at a database that already holds Broch data (a fresh key cannot decrypt the Data Protection keyring, IdP tokens, or license). Leave empty on a brand-new deploy: the template generates one and stores it in the created Key Vault. On any redeploy, supply the same key (read it from that Key Vault).')
@secure()
param brochMasterKey string = ''

@description('Internal — do not set. Entropy for the generated master key (used only when brochMasterKey is empty). newGuid() is valid only in a param default.')
@secure()
param masterKeySeed string = newGuid()

@description('Internal — do not set. Second entropy source for the generated master key.')
@secure()
param masterKeySeed2 string = newGuid()

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

// --- Generated secrets (used only when the corresponding input is empty). newGuid() is
// valid only in param defaults, so the entropy comes from the *Seed params above. Both are
// also written to the customer's Key Vault below so they survive VM recreation / redeploys. ---
var generatedMasterKey = base64('${masterKeySeed}-${masterKeySeed2}')
// Generate a master key ONLY for a brand-new Managed database — it has no existing state to
// decrypt, so a fresh key is safe. In Existing mode the database may already hold Broch data,
// so the key MUST be supplied; empty there yields an empty key and Broch fails loudly on boot
// rather than silently deploying a wrong key it can never decrypt with. (This is what keeps
// the prod dogfood — Existing + a supplied key — byte-for-byte unchanged.)
var generateMasterKey = empty(brochMasterKey) && databaseMode == 'Managed'
var effectiveMasterKey = !empty(brochMasterKey) ? brochMasterKey : (generateMasterKey ? generatedMasterKey : '')
// No SSH key supplied => provision a generated password (break-glass via Serial Console).
// The 'Aa1!' prefix guarantees Azure's complexity policy (upper + lower + digit + symbol).
var usePassword = empty(adminSshPublicKey)
var generatedVmPassword = 'Aa1!${vmPasswordSeed}'
// Only stand up a Key Vault when there's a generated secret to store. A deploy that supplies
// its own master key AND an SSH key (e.g. prod) creates no Key Vault and no new resources.
var needsKeyVault = generateMasterKey || usePassword

// --- TLS config selection ---
// Auto mode: the canonical Caddyfile imports a tls.caddy fragment (Cloudflare or Azure).
// Byo mode: the canonical BYO-cert Caddyfile (:443 catch-all) reads the supplied cert from
// /etc/caddy/certs; tls.caddy is unused. Both Caddyfiles come from broch-deploy (single source).
var azureTlsCaddy = 'tls {\n\tdns azure {\n\t\tsubscription_id {env.AZURE_SUBSCRIPTION_ID}\n\t\tresource_group_name {env.AZURE_DNS_RESOURCE_GROUP}\n\t}\n}\n'
var tlsCaddyContent = certMode == 'Byo' ? '# BYO-cert mode: TLS is set in the Caddyfile; this fragment is unused.\n' : (dnsProvider == 'AzureDns' ? azureTlsCaddy : loadTextContent('../../docker-compose/with-postgres-external/tls.caddy'))
var caddyfileContent = certMode == 'Byo' ? loadTextContent('../../docker-compose/with-postgres-byo-cert/Caddyfile') : loadTextContent('../../docker-compose/with-postgres-external/Caddyfile')
var azureSubscriptionId = (certMode == 'Auto' && dnsProvider == 'AzureDns') ? subscription().subscriptionId : ''

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
  ['__TLS_CERT_B64__', tlsCertificate]
  ['__TLS_KEY_B64__', tlsCertificateKey]
  // .env values — the template's .env.example surface (friendly names; the compose
  // fans BROCH_WILDCARD_HOSTNAME out to both Caddy and broch's API__WILDCARDHOSTNAME).
  ['__BROCH_VERSION__', brochVersion]
  ['__BROCH_MASTER_KEY__', effectiveMasterKey]
  ['__WILDCARD_HOSTNAME__', wildcardHostname]
  ['__CADDY_ACME_EMAIL__', acmeEmail]
  ['__CLOUDFLARE_API_TOKEN__', cloudflareApiToken]
  ['__AZURE_SUBSCRIPTION_ID__', azureSubscriptionId]
  ['__AZURE_DNS_RESOURCE_GROUP__', dnsZoneResourceGroup]
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

// --- Customer-owned secret store. Created ONLY when this deploy generates a secret (a
// Managed-mode master key and/or a break-glass VM password) — a deploy that brings its own
// master key and SSH key (e.g. prod) creates none of this. RBAC mode; this deployment writes
// the secrets via the control plane (the deployer's Contributor on the vault). To READ them,
// grant yourself — or set adminObjectId — the "Key Vault Secrets User" role. Generated secrets
// are born here, in your subscription; Broch never sees them. ---
var kvName = take('${vmName}-kv-${uniqueString(resourceGroup().id, vmName)}', 24)

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

resource kvMasterKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (generateMasterKey) {
  parent: keyVault
  name: 'broch-master-key'
  properties: { value: effectiveMasterKey }
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
    // Key Vault Secrets User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  // Azure-DNS auth uses the VM's managed identity (no secret to store); other TLS modes
  // need no identity. Grant this identity "DNS Zone Contributor" on the zone post-deploy.
  identity: (certMode == 'Auto' && dnsProvider == 'AzureDns') ? { type: 'SystemAssigned' } : null
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
module dnsRoleAssignment 'dns-role.bicep' = if (certMode == 'Auto' && dnsProvider == 'AzureDns' && !empty(dnsZoneResourceGroup)) {
  name: 'broch-dns-role'
  scope: resourceGroup(dnsZoneResourceGroup)
  params: {
    principalId: vm.identity!.principalId
  }
}

output publicIpAddress string = publicIp.properties.ipAddress
output dnsHint string = 'Create A records: ${wildcardHostname} and *.${wildcardHostname} -> ${publicIp.properties.ipAddress} (DNS-only / grey-cloud on Cloudflare)'
output databaseHost string = databaseMode == 'Managed' ? pgHost : 'external (you supplied the connection string)'
output keyVaultName string = keyVault.?name ?? ''
output masterKeySecretUri string = kvMasterKey.?properties.secretUri ?? ''
output managedIdentityPrincipalId string = vm.?identity.?principalId ?? ''
output dnsRoleAssignment string = (certMode == 'Auto' && dnsProvider == 'AzureDns') ? (empty(dnsZoneResourceGroup) ? 'Set dnsZoneResourceGroup to auto-grant, or grant the VM identity "DNS Zone Contributor" on your zone manually.' : 'DNS Zone Contributor granted automatically on resource group "${dnsZoneResourceGroup}".') : '(not using Azure DNS)'
output vmAccess string = usePassword ? 'No SSH key set; inbound SSH ${empty(sshAllowedCidr) ? 'closed' : 'limited to ${sshAllowedCidr}'}. Break-glass: Azure Serial Console as "${adminUsername}" (password in Key Vault secret "vm-admin-password"), or `az vm run-command`.' : 'SSH key set for "${adminUsername}"; inbound SSH ${empty(sshAllowedCidr) ? 'closed (set sshAllowedCidr to use it)' : 'limited to ${sshAllowedCidr}'}.'
