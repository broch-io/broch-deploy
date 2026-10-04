output "broch_url" {
  description = "Public HTTPS URL for the Broch server."
  value       = "https://${var.wildcard_hostname}"
}

output "alb_dns_name" {
  description = "ALB DNS name. The apex + wildcard records are aliased to this; useful for direct testing or external CNAMEs."
  value       = aws_lb.broch.dns_name
}

output "rds_endpoint" {
  description = "Postgres endpoint. Not reachable from the internet — only from ECS tasks in this VPC. Useful for break-glass via Session Manager or a bastion."
  value       = aws_db_instance.broch.address
}

output "secrets_arns" {
  description = "ARNs of the Secrets Manager secrets this stack creates. Terraform owns their values: rotate through Terraform (set the variable and `terraform apply`; for the generated Postgres password, `terraform apply -replace=random_password.postgres`), then force a new ECS deployment so the task reads them at start."
  value = {
    auth_client_secret = aws_secretsmanager_secret.auth_client_secret.arn
    postgres_password  = aws_secretsmanager_secret.postgres_password.arn
    connection_string  = aws_secretsmanager_secret.connection_string.arn
  }
}
