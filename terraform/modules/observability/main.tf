# ── Amazon Managed Prometheus ─────────────────────────────────────────────────

resource "aws_prometheus_workspace" "this" {
  alias = "northpay-${var.environment}"

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/northpay-${var.environment}"
  retention_in_days = 30
}

# ── Amazon Managed Grafana ────────────────────────────────────────────────────

resource "aws_grafana_workspace" "this" {
  name                     = "northpay-${var.environment}"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"

  data_sources = ["PROMETHEUS", "CLOUDWATCH"]

  role_arn = aws_iam_role.grafana.arn
}

resource "aws_iam_role" "grafana" {
  name = "northpay-${var.environment}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_prometheus" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# ── IRSA for Prometheus remote-write (ADOT collector) ────────────────────────

resource "aws_iam_role" "amp_ingest" {
  name = "${var.cluster_name}-amp-ingest"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:sub" = "system:serviceaccount:monitoring:amp-iamproxy-ingest-service-account"
          "${replace(var.oidc_provider_arn, "/^.*oidc-provider\\//", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "amp_ingest" {
  role       = aws_iam_role.amp_ingest.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}

# ── SNS alert topic ───────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "northpay-${var.environment}-alerts"
}
