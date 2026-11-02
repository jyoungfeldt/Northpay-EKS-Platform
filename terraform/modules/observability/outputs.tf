output "grafana_workspace_url" { value = "https://${aws_grafana_workspace.this.endpoint}" }
output "amp_workspace_id" { value = aws_prometheus_workspace.this.id }
output "amp_workspace_endpoint" { value = aws_prometheus_workspace.this.prometheus_endpoint }
output "amp_ingest_role_arn" { value = aws_iam_role.amp_ingest.arn }
