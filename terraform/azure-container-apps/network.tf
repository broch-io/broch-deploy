# Private network for the database.
#
# The Flexible Server is injected into a delegated subnet with a private DNS zone and NO public
# endpoint, and the Container Apps environment joins the same VNet so the app reaches the database
# privately. Nothing outside this VNet can connect to it. Ingress to the app stays public: the
# environment is external (not internal-load-balancer), so its *.azurecontainerapps.io FQDN and
# your custom domain work as before. Same layout as the Bicep azure-container-apps template.

locals {
  # From the /16: a /23 for the environment's infrastructure subnet (workload-profile
  # environments need /27 or larger) and a /28 for the database subnet. With the default
  # 10.2.0.0/16 these are 10.2.0.0/23 and 10.2.2.0/28.
  aca_subnet_prefix      = cidrsubnet(var.vnet_address_space, 7, 0)
  postgres_subnet_prefix = cidrsubnet(var.vnet_address_space, 12, 32)
}

resource "azurerm_virtual_network" "broch" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = azurerm_resource_group.broch.name
  location            = azurerm_resource_group.broch.location
  address_space       = [var.vnet_address_space]
}

resource "azurerm_subnet" "aca" {
  name                 = "aca-infra"
  resource_group_name  = azurerm_resource_group.broch.name
  virtual_network_name = azurerm_virtual_network.broch.name
  address_prefixes     = [local.aca_subnet_prefix]

  delegation {
    name = "aca-env"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.broch.name
  virtual_network_name = azurerm_virtual_network.broch.name
  address_prefixes     = [local.postgres_subnet_prefix]

  # Azure adds this endpoint when the server joins the subnet; declared so plans stay clean.
  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "pgflex"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Resolves the server's FQDN to its private address for everything in the VNet.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}-db.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.broch.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                 = "${var.name_prefix}-pg-link"
  private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  virtual_network_id   = azurerm_virtual_network.broch.id
  registration_enabled = false
}
