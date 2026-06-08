# RDS Postgres + Secrets Manager for the DB password.
#
# Single-AZ for cost. Use multi_az = true and a larger instance class for HA.

resource "random_password" "postgres" {
  length  = 32
  special = false # avoid characters that need URL-encoding in the connection string
}

# BROCH_MASTER_KEY — the customer-owned at-rest encryption root. Generated once
# here and stored in Secrets Manager; the server requires it at boot. It is never
# supplied by the operator and never leaves your account. Rotating it forces a
# one-time re-auth / license re-activation (state self-heals; nothing is bricked).
resource "random_password" "master_key" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-rds"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.name_prefix}-rds-subnets" }
}

resource "aws_db_instance" "broch" {
  identifier              = "${var.name_prefix}-postgres"
  engine                  = "postgres"
  engine_version          = "17"
  instance_class          = var.rds_instance_class
  allocated_storage       = var.rds_allocated_storage
  storage_encrypted       = true
  db_name                 = var.postgres_db_name
  username                = var.postgres_user
  password                = random_password.postgres.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true  # set to false for production; pair with final_snapshot_identifier
  deletion_protection     = false # set to true once you've moved past initial provisioning
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  apply_immediately = true
}

# ─── Secrets ─────────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "auth_client_secret" {
  name                    = "${var.name_prefix}/auth-client-secret"
  description             = "OAuth client secret for the configured identity provider (AUTHENTICATION__CLIENTSECRET)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "auth_client_secret" {
  secret_id     = aws_secretsmanager_secret.auth_client_secret.id
  secret_string = var.auth_client_secret
}

resource "aws_secretsmanager_secret" "master_key" {
  name                    = "${var.name_prefix}/master-key"
  description             = "Broch at-rest encryption master key (BROCH_MASTER_KEY). Generated, not supplied; the server won't start without it."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = random_password.master_key.result
}

resource "aws_secretsmanager_secret" "postgres_password" {
  name                    = "${var.name_prefix}/postgres-password"
  description             = "Postgres password for the broch DB. Rotated by editing this secret + restarting the ECS service."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "postgres_password" {
  secret_id     = aws_secretsmanager_secret.postgres_password.id
  secret_string = random_password.postgres.result
}

# Connection string is stored pre-assembled so the task definition can inject
# it as one secret rather than composing it from parts at runtime.
resource "aws_secretsmanager_secret" "connection_string" {
  name                    = "${var.name_prefix}/postgres-connection-string"
  description             = "Pre-composed Postgres connection string for broch."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "connection_string" {
  secret_id     = aws_secretsmanager_secret.connection_string.id
  secret_string = "Host=${aws_db_instance.broch.address};Port=${aws_db_instance.broch.port};Database=${var.postgres_db_name};Username=${var.postgres_user};Password=${random_password.postgres.result}"
}
