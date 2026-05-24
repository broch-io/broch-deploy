terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
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
