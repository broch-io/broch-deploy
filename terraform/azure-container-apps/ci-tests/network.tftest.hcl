# Mock providers only: `terraform test` here needs no Azure credentials and creates nothing.
# The database has no public endpoint and sits in its own subnet of the VNet; these pin that
# layout and the address-space rule.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
  }
}
mock_provider "random" {}

variables {
  auth_provider      = "Okta"
  auth_domain        = "tenant.okta.com"
  auth_client_id     = "client-id"
  auth_client_secret = "client-secret"
  wildcard_hostname  = "broch.example.com"
}

run "database_is_private" {
  command = plan
  plan_options {
    target = [azurerm_postgresql_flexible_server.broch]
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.broch.public_network_access_enabled == false
    error_message = "The database must have no public endpoint."
  }
}

run "default_subnets" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca, azurerm_subnet.postgres]
  }
  assert {
    condition     = azurerm_subnet.aca.address_prefixes == tolist(["10.2.0.0/23"]) && azurerm_subnet.postgres.address_prefixes == tolist(["10.2.2.0/28"])
    error_message = "Expected a /23 environment subnet and a /28 database subnet that don't overlap."
  }
}

run "database_subnet_and_dns_link" {
  # apply, not plan: the zone id is only known after apply (mocked, so nothing is created).
  command = apply
  plan_options {
    target = [azurerm_subnet.postgres, azurerm_private_dns_zone_virtual_network_link.postgres]
  }
  # Mock ids are random strings; the link (and teardown's destroy plan) parse these as Azure
  # resource ids.
  override_resource {
    target = azurerm_subnet.postgres
    values = {
      id = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/broch-rg/providers/Microsoft.Network/virtualNetworks/broch-vnet/subnets/postgres"
    }
  }
  override_resource {
    target = azurerm_virtual_network.broch
    values = {
      id = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/broch-rg/providers/Microsoft.Network/virtualNetworks/broch-vnet"
    }
  }
  override_resource {
    target = azurerm_private_dns_zone.postgres
    values = {
      id = "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/broch-rg/providers/Microsoft.Network/privateDnsZones/broch-db.private.postgres.database.azure.com"
    }
  }
  assert {
    condition     = length(azurerm_subnet.postgres.service_endpoint) == 1 && one(azurerm_subnet.postgres.service_endpoint).service == "Microsoft.Storage"
    error_message = "The database subnet should declare exactly the Microsoft.Storage service endpoint Azure adds."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.postgres.private_dns_zone_id == "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/broch-rg/providers/Microsoft.Network/privateDnsZones/broch-db.private.postgres.database.azure.com"
    error_message = "The VNet link should point at the database's private DNS zone."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.postgres.virtual_network_id == "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/broch-rg/providers/Microsoft.Network/virtualNetworks/broch-vnet"
    error_message = "The VNet link should attach the zone to the module's VNet."
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.postgres.registration_enabled == false
    error_message = "The VNet link should resolve only, not auto-register records."
  }
}

run "other_slash_16_is_accepted" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca, azurerm_subnet.postgres]
  }
  variables {
    vnet_address_space = "172.20.0.0/16"
  }
  assert {
    condition     = azurerm_subnet.aca.address_prefixes == tolist(["172.20.0.0/23"]) && azurerm_subnet.postgres.address_prefixes == tolist(["172.20.2.0/28"])
    error_message = "Subnets should follow the address space."
  }
}

run "larger_space_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca]
  }
  variables {
    vnet_address_space = "10.0.0.0/15"
  }
  expect_failures = [var.vnet_address_space]
}

run "smaller_space_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca]
  }
  variables {
    vnet_address_space = "10.2.0.0/24"
  }
  expect_failures = [var.vnet_address_space]
}

run "ipv6_space_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca]
  }
  variables {
    vnet_address_space = "fd00::/16"
  }
  expect_failures = [var.vnet_address_space]
}

run "host_address_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca]
  }
  variables {
    vnet_address_space = "10.2.5.0/16"
  }
  expect_failures = [var.vnet_address_space]
}

run "missing_prefix_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_subnet.aca]
  }
  variables {
    vnet_address_space = "10.2.0.0"
  }
  expect_failures = [var.vnet_address_space]
}
