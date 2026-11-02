module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  # Public endpoint for kubectl access during dev; restrict in prod
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable EKS Pod Identity (preferred over IRSA for new workloads)
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }

  # Karpenter manages worker nodes — we only need a small managed node group
  # for Karpenter itself and critical platform workloads
  eks_managed_node_groups = {
    platform = {
      name           = "platform"
      instance_types = ["m6g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"

      min_size     = 2
      max_size     = 4
      desired_size = 2

      labels = {
        role = "platform"
      }

      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# ── ECR repository for Ledger API ─────────────────────────────────────────────

resource "aws_ecr_repository" "ledger_api" {
  name                 = "northpay/ledger-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "ledger_api" {
  repository = aws_ecr_repository.ledger_api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 tagged images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["v"]
        countType     = "imageCountMoreThan"
        countNumber   = 20
      }
      action = { type = "expire" }
    }]
  })
}

# ── EBS CSI role (IRSA — Pod Identity doesn't support CSI yet) ────────────────

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
