# Mock providers only: `terraform test` here needs no AWS credentials and creates nothing.
# Broch refuses to start as Auth0 without an audience, so the plan must refuse first. Plans
# target the task definition (which carries the check): a mocked ACM certificate leaves the
# cert-validation for_each unknown at plan time, which the real provider does not.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  auth_client_id     = "client-id"
  auth_client_secret = "client-secret"
  route53_zone_id    = "ZEXAMPLEZONEID"
  wildcard_hostname  = "broch.example.com"
}

run "auth0_without_audience_is_refused" {
  command = plan
  plan_options {
    target = [aws_ecs_task_definition.broch]
  }
  variables {
    auth_provider = "auth0"
    auth_domain   = "tenant.auth0.com"
    auth_audience = "  "
  }
  expect_failures = [aws_ecs_task_definition.broch]
}

run "auth0_with_audience_is_accepted" {
  command = plan
  plan_options {
    target = [aws_ecs_task_definition.broch]
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
    target = [aws_ecs_task_definition.broch]
  }
  variables {
    auth_provider = "Okta"
    auth_domain   = "tenant.okta.com"
  }
}
