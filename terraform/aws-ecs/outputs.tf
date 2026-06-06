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
  description = "ARNs of the Secrets Manager secrets this stack creates. Rotate values via the AWS console / CLI; the ECS task picks up new values on the next deployment."
  value = {
    broch_license      = one(aws_secretsmanager_secret.broch_license[*].arn) # null when no license was supplied
    auth_client_secret = aws_secretsmanager_secret.auth_client_secret.arn
    postgres_password  = aws_secretsmanager_secret.postgres_password.arn
    connection_string  = aws_secretsmanager_secret.connection_string.arn
    ghcr_pull          = aws_secretsmanager_secret.ghcr_pull.arn
  }
}
