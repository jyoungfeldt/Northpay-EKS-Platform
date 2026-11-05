module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name           = var.cluster_name
  irsa_oidc_provider_arn = var.oidc_provider_arn

  # Pod Identity (preferred over IRSA)
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Use an explicit short name to avoid the 38-char name_prefix limit
  node_iam_role_name            = "northpay-karpenter-node"
  node_iam_role_use_name_prefix = false

  tags = {
    Environment = var.environment
  }
}

# ── Install Karpenter via Helm ─────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.1.1"
  create_namespace = false
  wait             = false

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
    })
  ]

  depends_on = [module.karpenter]
}

# ── Default NodePool ───────────────────────────────────────────────────────────

resource "kubectl_manifest" "node_pool_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["arm64"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["m", "c", "r"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
          ]
        }
      }
      limits = {
        cpu    = "100"
        memory = "400Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "ec2_node_class_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms = [{ alias = "al2023@latest" }]
      role             = "northpay-karpenter-node"
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      tags = { Environment = var.environment }
    }
  })

  depends_on = [helm_release.karpenter]
}
