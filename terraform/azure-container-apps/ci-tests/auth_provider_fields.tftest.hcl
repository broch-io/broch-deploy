# Mock providers only: `terraform test` here needs no Azure credentials and creates nothing.
# Broch refuses to start without each provider's required values, so the plan must refuse
# first. Plans target the container app, which carries the checks.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" }
  }
}
mock_provider "random" {}

variables {
  auth_client_id     = "client-id"
  auth_client_secret = "client-secret"
  wildcard_hostname  = "broch.example.com"
}

run "azuread_without_instance_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "AzureAd"
    auth_tenant_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }
  expect_failures = [azurerm_container_app.broch]
}

run "entra_external_id_without_tenant_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "entraexternalid"
    auth_instance = "https://tenant.ciamlogin.com/"
  }
  expect_failures = [azurerm_container_app.broch]
}

run "azuread_with_authority_needs_no_instance" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "AzureAd"
    auth_authority = "https://login.microsoftonline.com/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/v2.0"
  }
}

run "okta_without_domain_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "Okta"
  }
  expect_failures = [azurerm_container_app.broch]
}

run "okta_with_domain_is_accepted" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "Okta"
    auth_domain   = "tenant.okta.com"
  }
}

run "oidc_without_authority_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "Oidc"
    auth_domain   = "idp.example.com"
  }
  expect_failures = [azurerm_container_app.broch]
}

run "oidc_with_authority_is_accepted" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "Oidc"
    auth_authority = "https://idp.example.com"
  }
}

run "unknown_provider_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "Google"
    auth_domain   = "example.com"
  }
  expect_failures = [var.auth_provider]
}

run "provider_without_client_secret_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider      = "Okta"
    auth_domain        = "tenant.okta.com"
    auth_client_secret = ""
  }
  expect_failures = [azurerm_container_app.broch]
}

run "blank_provider_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = " "
    auth_tenant_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }
  expect_failures = [var.auth_provider]
}

run "provider_without_client_id_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "Okta"
    auth_domain    = "tenant.okta.com"
    auth_client_id = ""
  }
  expect_failures = [azurerm_container_app.broch]
}

run "azuread_without_tenant_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "AzureAd"
    auth_instance  = "https://login.microsoftonline.com/"
    auth_tenant_id = ""
  }
  expect_failures = [azurerm_container_app.broch]
}

run "entra_external_id_with_authority_is_accepted" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "EntraExternalId"
    auth_instance  = ""
    auth_authority = "https://tenant.ciamlogin.com/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/v2.0"
  }
}

run "auth0_without_domain_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = "Auth0"
    auth_audience = "https://api.example.com"
  }
  expect_failures = [azurerm_container_app.broch]
}

run "auth0_with_authority_needs_no_domain" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider  = "Auth0"
    auth_authority = "https://tenant.auth0.com/"
    auth_audience  = "https://api.example.com"
  }
}

run "padded_lowercase_provider_is_accepted" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider = " okta "
    auth_domain   = "tenant.okta.com"
  }
}

run "blank_wildcard_hostname_is_refused" {
  command = plan
  plan_options {
    target = [azurerm_container_app.broch]
  }
  variables {
    auth_provider     = "Okta"
    auth_domain       = "tenant.okta.com"
    wildcard_hostname = " "
  }
  expect_failures = [var.wildcard_hostname]
}
