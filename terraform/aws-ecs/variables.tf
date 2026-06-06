# ─── User inputs ─────────────────────────────────────────────────────────────
# Required values you must set in terraform.tfvars (see terraform.tfvars.example).

variable "wildcard_hostname" {
  description = "Wildcard DNS hostname for Broch tunnels (e.g. tunnels.example.com). The ACM cert covers both this hostname AND *.<hostname>. You must own the Route 53 zone."
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID containing the wildcard hostname. Used for ACM DNS validation and for creating the A-ALIAS record pointing at the ALB."
  type        = string
}

# ─── Identity provider (required at boot) ────────────────────────────────────
# Broch authenticates every user through your IdP — there is no built-in local
# login, so the IdP is part of the boot floor. The server starts without these,
# but no one can sign in (or finish first-run setup) until they're set. Set the
# provider-specific values your IdP needs; leave the rest blank.
# Guides: https://broch.io/docs/identity-providers/

variable "auth_provider" {
  description = "Identity provider type: Auth0 | AzureAd | EntraExternalId | Okta | Oidc."
  type        = string
}

variable "auth_client_id" {
  description = "OAuth client ID from your IdP."
  type        = string
}

variable "auth_client_secret" {
  description = "OAuth client secret from your IdP. Stored in AWS Secrets Manager; not committed to state or logs."
  type        = string
  sensitive   = true
}

variable "auth_admin_roles" {
  description = "Comma-separated role/group names that grant admin access. Your first admin signs in holding one of these."
  type        = string
  default     = "broch_admin"
}

variable "auth_domain" {
  description = "IdP domain — required for Auth0 and Okta (e.g. your-tenant.auth0.com). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_tenant_id" {
  description = "Tenant ID — required for AzureAd and EntraExternalId. Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_instance" {
  description = "Login instance for AzureAd/EntraExternalId (e.g. https://login.microsoftonline.com/). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_authority" {
  description = "Issuer URL — required for the generic Oidc provider (serves /.well-known/openid-configuration). Leave blank for other providers."
  type        = string
  default     = ""
}

variable "auth_audience" {
  description = "OAuth audience identifier. Optional; falls back to the client ID."
  type        = string
  default     = ""
}

# ─── License (optional at boot) ──────────────────────────────────────────────

variable "broch_license" {
  description = "Broch license key. Optional at boot — leave blank to activate in-app on first sign-in (Admin → License), or set it to pre-seed activation. Stored in AWS Secrets Manager when set."
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_pat" {
  description = "GitHub Personal Access Token with read:packages, used by ECS to pull the broch image from GHCR while the image is private. Stored in AWS Secrets Manager."
  type        = string
  sensitive   = true
}

variable "github_username" {
  description = "GitHub username paired with github_pat for GHCR auth."
  type        = string
}

# ─── Optional inputs (sensible defaults) ─────────────────────────────────────

variable "broch_image" {
  description = "Full image reference for the broch server. Pin to a specific version in production."
  type        = string
  default     = "ghcr.io/broch-io/broch:latest"
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
