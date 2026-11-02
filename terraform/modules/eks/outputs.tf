output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" { value = module.eks.cluster_certificate_authority_data }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "oidc_provider" { value = module.eks.oidc_provider }
output "node_iam_role_name" { value = module.eks.eks_managed_node_groups["platform"].iam_role_name }
output "node_security_group_id" { value = module.eks.node_security_group_id }
output "ecr_repository_url" { value = aws_ecr_repository.ledger_api.repository_url }
