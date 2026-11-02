module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.14"

  name = var.name
  cidr = var.cidr

  azs             = var.availability_zones
  private_subnets = [for k, v in var.availability_zones : cidrsubnet(var.cidr, 4, k)]
  public_subnets  = [for k, v in var.availability_zones : cidrsubnet(var.cidr, 8, k + 48)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment == "dev" ? true : false  # save cost in dev
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # Required tags for AWS Load Balancer Controller subnet discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

# ── VPC Endpoints ─────────────────────────────────────────────────────────────
# Keeps ECR/S3/SSM traffic off the public internet and avoids NAT Gateway charges

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.14"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
    ecr_api = {
      service             = "ecr.api"
      service_type        = "Interface"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      service_type        = "Interface"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
    }
    sts = {
      service             = "sts"
      service_type        = "Interface"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
    }
    ssm = {
      service             = "ssm"
      service_type        = "Interface"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
    }
  }
}
