output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "ecr_repository_url" {
  description = "ECR repository URL for Ledger API"
  value       = module.eks.ecr_repository_url
}

output "aurora_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.aurora.cluster_endpoint
  sensitive   = true
}

output "grafana_workspace_url" {
  description = "Amazon Managed Grafana workspace URL"
  value       = module.observability.grafana_workspace_url
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
