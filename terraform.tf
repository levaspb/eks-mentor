variable "access_key" {}
variable "secret_key" {}
variable "env_prefix" {}
variable "region" {}
variable "vpc_cidr_block" {}
variable "private_subnets" {}
variable "public_subnets" {}

provider "aws" {
  secret_key = var.secret_key
  access_key = var.access_key
  region = var.region
}

data "aws_eks_cluster" "mentor-cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "mentor-cluster" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host = data.aws_eks_cluster.mentor-cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.mentor-cluster.certificate_authority.0.data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "mentor-vps"
  cidr = var.vpc_cidr_block

  azs             = data.aws_availability_zones.available.names
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true
  # enable_vpn_gateway = true

  tags = {
    Terraform = "true"
    Environment = var.env_prefix
    "kubernetes.io/cluster/mentor-cluster" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/mentor-cluster" = "shared"
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/mentor-cluster" = "shared"
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "mentor-cluster"
  cluster_version = "1.24"

  cluster_endpoint_public_access  = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets
  
 
  # Self Managed Node Group(s)
  self_managed_node_group_defaults = {
    instance_type                          = "t2.micro"
    update_launch_template_default_version = true
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  self_managed_node_groups = {
    one = {
      name         = "mixed-1"
      max_size     = 5
      desired_size = 2

      use_mixed_instances_policy = true
      mixed_instances_policy = {
        instances_distribution = {
          on_demand_base_capacity                  = 0
          on_demand_percentage_above_base_capacity = 10
          spot_allocation_strategy                 = "capacity-optimized"
        }

        override = [
          {
            instance_type     = "t2.micro"
            weighted_capacity = "1"
          },
          {
            instance_type     = "t2.small"
            weighted_capacity = "2"
          },
        ]
      }
    }
  }

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = ["t2.micro", "t2.small"]
  }

  eks_managed_node_groups = {
    blue = {}
    green = {
      min_size     = 1
      max_size     = 10
      desired_size = 1

      instance_types = ["t2.micro"]
      capacity_type  = "SPOT"
    }
  }

  # Fargate Profile(s)
  fargate_profiles = {
    default = {
      name = "default"
      selectors = [
        {
          namespace = "default"
        }
      ]
    }
  }

  tags = {
    Environment = var.env_prefix
    Terraform   = "true"
  }
}
