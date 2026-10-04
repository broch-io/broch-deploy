# ─── User inputs ─────────────────────────────────────────────────────────────
# Required values you must set in terraform.tfvars (see terraform.tfvars.example).

variable "wildcard_hostname" {
  description = "Wildcard DNS hostname for Broch tunnels (e.g. broch.example.com). The ACM cert covers both this hostname AND *.<hostname>. You must own the Route 53 zone."
  type        = string

  validation {
    condition     = trimspace(var.wildcard_hostname) != ""
    error_message = "wildcard_hostname is required: Broch refuses to start without it."
  }
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID containing the wildcard hostname. Used for ACM DNS validation and for creating the A-ALIAS record pointing at the ALB."
  type        = string
}

# ─── Identity provider (required at boot) ────────────────────────────────────
# Broch authenticates every user through your IdP — there is no built-in local
# login, so the IdP is part of the boot floor. Set the provider-specific values
# your IdP needs and leave the rest blank; the plan refuses a combination Broch
# would refuse at startup.
# Guides: https://broch.io/docs/identity-providers/

variable "auth_provider" {
  description = "Identity provider type: Auth0 | AzureAd | EntraExternalId | Okta | Oidc."
  type        = string

  # Matched case-insensitively, as Broch binds it.
  validation {
    condition     = contains(["auth0", "azuread", "entraexternalid", "okta", "oidc"], lower(trimspace(var.auth_provider)))
    error_message = "auth_provider must be one of Auth0, AzureAd, EntraExternalId, Okta, Oidc."
  }
}

variable "auth_client_id" {
  description = "OAuth client ID from your IdP."
  type        = string
}

variable "auth_client_secret" {
  description = "OAuth client secret from your IdP. Stored in AWS Secrets Manager and, in plaintext, in Terraform state (sensitive keeps it out of plan and apply output); keep state access-controlled."
  type        = string
  sensitive   = true
}

variable "auth_admin_roles" {
  description = "Comma-separated role/group names that grant admin access. Your first admin signs in holding one of these."
  type        = string
  default     = "broch_admin"
}

variable "auth_domain" {
  description = "IdP domain — required for Auth0 and Okta (e.g. your-tenant.auth0.com) unless auth_authority is set. Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_tenant_id" {
  description = "Tenant ID — required for AzureAd and EntraExternalId unless auth_authority is set. Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_instance" {
  description = "Login instance — required for AzureAd (https://login.microsoftonline.com/) and EntraExternalId (https://<tenant>.ciamlogin.com/) unless auth_authority is set. Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_authority" {
  description = "Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_audience" {
  description = "Auth0 API audience — required for Auth0: the Identifier of the Auth0 API your Broch application has user access to. Leave blank for other providers."
  type        = string
  default     = ""
}

# ─── Optional inputs (sensible defaults) ─────────────────────────────────────

variable "broch_image" {
  description = "Full image reference for the broch server. Defaults to a concrete pinned version (NOT :latest) so a task redeploy never silently rolls the service across an EF-migration boundary; new releases of this template bump this default. To upgrade deliberately, set a newer tag, then apply and run `aws ecs update-service --task-definition broch-broch` (see README); :latest floats (not recommended in production)."
  type        = string
  default     = "ghcr.io/broch-io/broch:1.35.0"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Pick something that doesn't overlap your other networks if you peer."
  type        = string
  default     = "10.42.0.0/16"
}

variable "task_cpu" {
  description = "Fargate task CPU units. 512 = 0.5 vCPU, 1024 = 1 vCPU, 2048 = 2 vCPU."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Must be valid for the chosen CPU — see https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-defs.html"
  type        = number
  default     = 1024
}

variable "rds_instance_class" {
  description = "RDS instance class. db.t4g.micro is cheap and sufficient for small workloads."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS storage in GB."
  type        = number
  default     = 20
}

variable "rds_deletion_protection" {
  description = "RDS deletion protection. On by default so a destroy or replacing change can't delete the database (no final snapshot is taken). Set false and apply before an intentional destroy."
  type        = bool
  default     = true
}

variable "postgres_db_name" {
  description = "Postgres database name."
  type        = string
  default     = "brochdb"
}

variable "postgres_user" {
  description = "Postgres master username."
  type        = string
  default     = "broch"
}

variable "name_prefix" {
  description = "Prefix applied to all named AWS resources. Use this to deploy multiple broch stacks in one account/region."
  type        = string
  default     = "broch"
}
