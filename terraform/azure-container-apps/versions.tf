terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # Register what this module deploys (Microsoft.Resources and Microsoft.Authorization
  # are registered in every subscription by default). azurerm 5 registers nothing on its
  # own, so this list must name every provider the module needs; a missing one fails a
  # fresh subscription with MissingSubscriptionRegistration. Microsoft.ContainerService is
  # required for a Container Apps environment in a custom VNet. Only unregistered providers
  # are registered.
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ContainerService",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
  ]

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Soft-delete + purge protection are now ON by default in this provider.
      # Letting purge-on-destroy stay false means deleting the key vault keeps
      # secrets recoverable for the retention window. Override if you need
      # clean teardowns.
      purge_soft_delete_on_destroy = false
    }
  }
}
