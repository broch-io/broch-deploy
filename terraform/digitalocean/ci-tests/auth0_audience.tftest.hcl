# Mock providers only: `terraform test` here needs no DigitalOcean token and creates nothing.
# Broch refuses to start as Auth0 without an audience, so the plan must refuse first. Plans
# target the droplet, which carries the check.

mock_provider "digitalocean" {}

variables {
  auth_client_id      = "client-id"
  auth_client_secret  = "client-secret"
  dns_api_token       = "dns-token"
  do_token            = "do-token"
  ssh_key_fingerprint = "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00"
  wildcard_hostname   = "broch.example.com"
}

run "auth0_without_audience_is_refused" {
  command = plan
  plan_options {
    target = [digitalocean_droplet.broch]
  }
  variables {
    auth_provider = "auth0"
    auth_domain   = "tenant.auth0.com"
    auth_audience = "  "
  }
  expect_failures = [digitalocean_droplet.broch]
}

run "auth0_with_audience_is_accepted" {
  command = plan
  plan_options {
    target = [digitalocean_droplet.broch]
  }
  variables {
    auth_provider = "Auth0"
    auth_domain   = "tenant.auth0.com"
    auth_audience = "https://api.example.com"
  }
}

run "other_providers_need_no_audience" {
  command = plan
  plan_options {
    target = [digitalocean_droplet.broch]
  }
  variables {
    auth_provider  = "AzureAd"
    auth_tenant_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }
}
