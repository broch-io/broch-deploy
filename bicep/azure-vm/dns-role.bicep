// Grants a principal the "DNS Zone Contributor" role at this resource group's scope.
// main.bicep deploys this at the DNS zone's resource group so the VM's managed identity can
// complete Caddy's ACME DNS-01 challenge (write/cleanup TXT records) with no manual grant.
// Scoped to the RG rather than a single zone because Caddy is configured with the resource
// group and resolves the zone from the hostname.
// Copyright (c) 2026 Broch, LLC. All rights reserved.

@description('Principal (the VM managed identity) to grant DNS Zone Contributor.')
param principalId string

@description('DNS Zone Contributor role definition ID.')
param roleDefinitionId string = 'befefa01-2a29-4197-83a8-272ff33ce314'

resource dnsZoneContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}
