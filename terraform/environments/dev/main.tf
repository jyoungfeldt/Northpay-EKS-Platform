terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }

  backend "s3" {
    bucket         = "northpay-tfstate-595981720885"   # create this bucket first
    key            = "eks-platform/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "northpay-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "northpay-eks-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "../../modules/vpc"

  name               = "northpay-${var.environment}"
  cidr               = "10.0.0.0/16"
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
  environment        = var.environment
  cluster_name       = local.cluster_name
}

# ── EKS ───────────────────────────────────────────────────────────────────────

module "eks" {
  source  = "../../modules/eks"

  cluster_name       = local.cluster_name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  environment        = var.environment
  aws_account_id     = data.aws_caller_identity.current.account_id
  aws_region         = var.aws_region
}

# ── Karpenter ─────────────────────────────────────────────────────────────────

module "karpenter" {
  source  = "../../modules/karpenter"

  cluster_name       = module.eks.cluster_name
  cluster_endpoint   = module.eks.cluster_endpoint
  oidc_provider_arn  = module.eks.oidc_provider_arn
  node_iam_role_name = module.eks.node_iam_role_name
  environment        = var.environment

  depends_on = [module.eks]
}

# ── ALB Controller ────────────────────────────────────────────────────────────

module "alb_controller" {
  source  = "../../modules/alb-controller"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  aws_account_id    = data.aws_caller_identity.current.account_id
  aws_region        = var.aws_region
  environment       = var.environment

  depends_on = [module.eks]
}

# ── Aurora ────────────────────────────────────────────────────────────────────

module "aurora" {
  source  = "../../modules/aurora"

  name               = "northpay-${var.environment}"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  environment        = var.environment
  aws_region         = var.aws_region
}

# ── Observability ─────────────────────────────────────────────────────────────

module "observability" {
  source  = "../../modules/observability"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  aws_account_id    = data.aws_caller_identity.current.account_id
  aws_region        = var.aws_region
  environment       = var.environment

  depends_on = [module.eks]
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  cluster_name = "northpay-${var.environment}"
}
