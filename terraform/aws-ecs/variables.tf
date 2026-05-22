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

variable "broch_license" {
  description = "Broch license key. Stored in AWS Secrets Manager; not committed to state or logs."
  type        = string
  sensitive   = true
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
