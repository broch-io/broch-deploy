mock_provider "digitalocean" {}

variables {
  do_token            = "test-token"
  ssh_key_fingerprint = "test-key"
  wildcard_hostname   = "qa.example.com"
  dns_api_token       = "test-dns"
  auth_provider       = "Auth0"
  auth_client_id      = "test-client"
  auth_client_secret  = "test-secret"
  auth_domain         = "test.auth0.com"
  auth_audience       = "test-api"
}

run "public_image" {
  command = plan
  assert {
    condition     = length(jsondecode(base64decode(local.registry_config)).auths) == 0
    error_message = "A public image must not receive registry credentials."
  }
}

run "private_image_literal_credentials" {
  command = plan
  variables {
    registry_server   = "ghcr.io"
    registry_username = "qa-puller"
    registry_password = "quote' dollar$ backtick` newline\ncolon: slash\\ end"
  }
  assert {
    condition     = base64decode(jsondecode(base64decode(local.registry_config)).auths["ghcr.io"].auth) == "qa-puller:quote' dollar$ backtick` newline\ncolon: slash\\ end"
    error_message = "Registry credentials must survive encoding literally."
  }
}

run "incomplete_private_credentials" {
  command = plan
  variables {
    registry_server   = "ghcr.io"
    registry_username = "qa-puller"
  }
  expect_failures = [digitalocean_droplet.broch]
}

run "reject_registry_url" {
  command = plan
  variables {
    registry_server   = "https://ghcr.io/path"
    registry_username = "qa-puller"
    registry_password = "test"
  }
  expect_failures = [var.registry_server]
}

run "reject_image_registry_mismatch" {
  command = plan
  variables {
    image             = "ghcr.io/broch-io/private"
    registry_server   = "other.example.com"
    registry_username = "test"
    registry_password = "test"
  }
  expect_failures = [digitalocean_droplet.broch]
}

run "docker_hub_canonical_key" {
  command = plan
  variables {
    image             = "qa/private"
    registry_server   = "docker.io"
    registry_username = "test"
    registry_password = "test"
  }
  assert {
    condition     = base64decode(jsondecode(base64decode(local.registry_config)).auths["https://index.docker.io/v1/"].auth) == "test:test"
    error_message = "Docker Hub needs its canonical legacy auth key."
  }
}

run "docker_hub_index_alias_with_implicit_image" {
  command = plan
  variables {
    image             = "qa/private"
    registry_server   = "index.docker.io"
    registry_username = "test"
    registry_password = "test"
  }
  assert {
    condition     = contains(keys(jsondecode(base64decode(local.registry_config)).auths), "https://index.docker.io/v1/")
    error_message = "Docker Hub aliases must match implicit Docker Hub images."
  }
}

run "docker_hub_index_image_with_canonical_registry" {
  command = plan
  variables {
    image             = "index.docker.io/qa/private"
    registry_server   = "docker.io"
    registry_username = "test"
    registry_password = "test"
  }
  assert {
    condition     = local.image_registry == "docker.io"
    error_message = "An explicit index.docker.io image is Docker Hub."
  }
}

run "uppercase_single_component_registry" {
  command = plan
  variables {
    image             = "INTERNAL/private"
    registry_server   = "internal"
    registry_username = "test"
    registry_password = "test"
  }
  assert {
    condition     = local.image_registry == "internal"
    error_message = "An uppercase first component is a Docker registry, not a namespace."
  }
}
