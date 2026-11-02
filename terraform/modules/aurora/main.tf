module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.11"

  name              = var.name
  engine            = "aurora-postgresql"
  engine_mode       = "provisioned"
  engine_version    = "16.4"
  storage_encrypted = true

  vpc_id               = var.vpc_id
  db_subnet_group_name = aws_db_subnet_group.this.name
  security_group_rules = {
    eks_ingress = {
      type                     = "ingress"
      from_port                = 5432
      to_port                  = 5432
      protocol                 = "tcp"
      source_security_group_id = var.eks_node_sg_id
    }
  }

  # Aurora Serverless v2 — scales from 0.5 to 8 ACUs
  serverlessv2_scaling_configuration = {
    min_capacity = 0.5
    max_capacity = 8
  }

  instance_class = "db.serverless"
  instances = {
    writer = {}
  }

  database_name   = "northpay"
  master_username = "northpay_admin"

  # Credentials managed by Secrets Manager — rotated automatically
  manage_master_user_password = true

  backup_retention_period = 7
  skip_final_snapshot     = var.environment == "dev" ? true : false

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Environment = var.environment
  }
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.private_subnet_ids
}

# ── Store DB connection details in Secrets Manager for ESO ───────────────────

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "northpay/${var.environment}/db-credentials"
  recovery_window_in_days = var.environment == "dev" ? 0 : 30

  tags = { Environment = var.environment }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    host     = module.aurora.cluster_endpoint
    port     = 5432
    database = "northpay"
    username = module.aurora.cluster_master_username
    # password is in the Aurora-managed secret; reference that ARN here
    aurora_secret_arn = module.aurora.cluster_master_user_secret[0].secret_arn
  })
}
