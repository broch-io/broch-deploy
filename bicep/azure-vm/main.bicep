// Broch — Azure VM appliance (Bicep). DRAFT / local-first — see README.md.
// Boots the with-postgres + Caddy Docker Compose stack on an Ubuntu 24.04 VM:
// the VM path for Azure (alongside the existing ACA Bicep), and the substrate
// Broch's own prod dogfoods.
// Copyright (c) 2026 Broch, LLC. All rights reserved.

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Base name for the VM and its resources.')
param vmName string = 'broch'

@description('VM size. Default is x86 burstable (widely available). For ARM64 (cheaper, where capacity exists) pick an Ampere size (e.g. Standard_D2ps_v6) AND set imageSku to the arm64 SKU — the broch image is multi-arch.')
param vmSize string = 'Standard_B2s'

@description('Ubuntu image SKU — must match the VM architecture: "server" for x86 sizes, "server-arm64" for ARM (Ampere) sizes.')
param imageSku string = 'server'

@description('Admin username for SSH.')
param adminUsername string = 'broch'

@description('SSH public key for the admin user.')
param adminSshPublicKey string

@description('Wildcard hostname for tunnels + API, e.g. tunnels.example.com. You must own this domain and point its DNS at this VM (see README).')
param wildcardHostname string

@description('Email Let\'s Encrypt notifies about cert-renewal failures.')
param acmeEmail string

@description('Cloudflare API token (Zone:Read + DNS:Edit) for the zone hosting wildcardHostname. Used by Caddy for ACME DNS-01.')
@secure()
param cloudflareApiToken string

@description('Broch server image tag. Pin in production.')
param brochVersion string = 'latest'

@description('CIDR allowed to reach SSH (port 22). Empty (default) creates NO inbound SSH rule — the box is managed via `az vm run-command` / Azure Serial Console, the secure default. Set a CIDR (e.g. your admin network) to allow SSH break-glass.')
param sshAllowedCidr string = ''

@description('The EXISTING Broch master key the target database was encrypted with. A fresh key cannot decrypt existing state (Data Protection keyring, IdP tokens, license) — reuse the current one.')
@secure()
param brochMasterKey string

@description('Connection string for the existing external PostgreSQL (e.g. Azure Database for PostgreSQL Flexible Server). Npgsql format, including SSL mode.')
@secure()
param databaseConnectionString string

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

// cloud-init.yaml carries __TOKEN__ placeholders; substitute them before base64.
// Token→value table folded over the file with reduce(). The base64 blobs are pure
// base64 (no underscores), so they never collide with a __TOKEN__ placeholder.
var cloudInitTokens = [
  // Canonical compose stack, embedded VERBATIM (base64) from the shared
  // docker-compose/with-postgres-external template — single source of truth, so the
  // VM runs the same bytes as a docker-direct customer and the two cannot drift.
  ['__COMPOSE_B64__', base64(loadTextContent('../../docker-compose/with-postgres-external/docker-compose.yml'))]
  ['__CADDYFILE_B64__', base64(loadTextContent('../../docker-compose/with-postgres-external/Caddyfile'))]
  ['__CADDY_DOCKERFILE_B64__', base64(loadTextContent('../../docker-compose/with-postgres-external/Caddy.Dockerfile'))]
  // .env values — the template's .env.example surface (friendly names; the compose
  // fans BROCH_WILDCARD_HOSTNAME out to both Caddy and broch's API__WILDCARDHOSTNAME).
  ['__BROCH_VERSION__', brochVersion]
  ['__BROCH_MASTER_KEY__', brochMasterKey]
  ['__WILDCARD_HOSTNAME__', wildcardHostname]
  ['__CADDY_ACME_EMAIL__', acmeEmail]
  ['__CLOUDFLARE_API_TOKEN__', cloudflareApiToken]
  ['__DATABASE_CONNECTION_STRING__', databaseConnectionString]
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

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
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
}

output publicIpAddress string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output dnsHint string = 'Create A records: ${wildcardHostname} and *.${wildcardHostname} -> ${publicIp.properties.ipAddress} (DNS-only / grey-cloud on Cloudflare)'
