// Managed-mode Azure Database for PostgreSQL Flexible Server, split into a MODULE for one reason:
// administratorLoginPassword is fed by the parent via kv.getSecret('pg-admin-password') — a Key Vault
// reference ARM resolves at deployment time — and getSecret() values can only flow into a module's
// @secure() parameter, never into a same-file resource property. This is what lets a Redeploy retry
// leave postgresAdminPassword blank: the parent skips the secret write (blank never overwrites) and
// this module receives the value the FIRST attempt stored, so the server is created — or re-PUT —
// with the original password.
//
// The db-connection-string secret is written HERE, from the SAME resolved password that configures
// the server — one source, so the server's live password and the stored connection string cannot be
// written from different values. A rotation deployment that fails partway can still leave the pair
// momentarily split (two resources), but the next retry — even master-key-only — re-derives BOTH
// from the stored pg-admin-password and converges them, instead of ratifying the split.
// Copyright (c) 2026 Broch, LLC. All rights reserved.

param location string
param kvName string
param pgServerName string
param pgAdminUser string
param pgDatabaseName string
param postgresSkuName string
@secure()
param administratorLoginPassword string
param delegatedSubnetResourceId string
param privateDnsZoneArmResourceId string

// Private access: injected into the delegated subnet + resolvable via the private DNS zone. No
// public endpoint (publicNetworkAccess can't be Enabled with a delegated subnet). Same resource
// shape as when this lived inline in main.bicep — only the password's SOURCE changed.
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: pgServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: startsWith(postgresSkuName, 'Standard_B') ? 'Burstable' : 'GeneralPurpose'
  }
  properties: {
    version: '16'
    administratorLogin: pgAdminUser
    administratorLoginPassword: administratorLoginPassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: {
      delegatedSubnetResourceId: delegatedSubnetResourceId
      privateDnsZoneArmResourceId: privateDnsZoneArmResourceId
    }
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: postgres
  name: pgDatabaseName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: kvName
}

// The connection Host is the server's real FQDN, NOT a name under the private DNS zone: Azure
// registers the zone's A record under an instance-specific label, and aliases the real FQDN to it
// inside the VNet (same construction the parent used when this was composed there). Written on
// every Managed deploy — the value derives from this module's resolved password, so overwriting is
// always convergence, never clobbering.
// The password is SINGLE-QUOTED with embedded quotes doubled — Npgsql's value-quoting rule. Azure
// accepts ';' and '\'' in a flexible-server password, and interpolating those raw would silently
// corrupt the pair syntax: every resource deploys, ARM reports success, and broch crash-loops at
// boot on a malformed connection string with nothing pointing at the password.
var pgPasswordQuoted = '\'${replace(administratorLoginPassword, '\'', '\'\'')}\''
resource secDbConnManaged 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'db-connection-string'
  properties: { value: 'Host=${pgServerName}.postgres.database.azure.com;Port=5432;Database=${pgDatabaseName};Username=${pgAdminUser};Password=${pgPasswordQuoted};SSL Mode=Require' }
}
