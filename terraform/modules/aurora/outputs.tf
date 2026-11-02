output "cluster_endpoint" { value = module.aurora.cluster_endpoint }
output "db_secret_arn" { value = aws_secretsmanager_secret.db_credentials.arn }
