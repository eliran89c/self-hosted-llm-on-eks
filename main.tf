################################################################################
# Common locals
################################################################################
locals {
  name   = "self-hosted-llm"
  region = "us-west-2"

  vpc_cidr   = "10.0.0.0/16"
  num_of_azs = 2

  tags = {
    GithubRepo       = "https://github.com/eliran89c/self-hosted-llm-on-eks"
    BaseEKSBlueprint = "github.com/aws-ia/terraform-aws-eks-blueprints/patterns/karpenter"
  }
}

################################################################################
# Providers
################################################################################
provider "aws" {
  region = local.region
}

# Required for public ECR where Karpenter artifacts are hosted
provider "aws" {
  region = "us-east-1"
  alias  = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

################################################################################
# Data
################################################################################
data "aws_availability_zones" "available" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.us-east-1
}

################################################################################
# Network
################################################################################
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

################################################################################
# Cluster
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.name
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Give the Terraform identity admin access to the cluster
  # which will allow it to deploy resources into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  # Fargate profiles use the cluster primary security group
  # Therefore these are not used and can be skipped
  create_cluster_security_group = false
  create_node_security_group    = false

  fargate_profiles = {
    karpenter = {
      selectors = [
        { namespace = "karpenter" }
      ]
    }
    kube_system = {
      name = "coredns"
      selectors = [
        { namespace = "kube-system", labels = { "k8s-app" = "kube-dns" } }
      ]
    }
  }

  tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })
}

################################################################################
# Core addons
################################################################################
module "core_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.19"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # We want to wait for the Fargate profiles to be deployed first
  create_delay_dependencies = [for prof in module.eks.fargate_profiles : prof.fargate_profile_arn]

  eks_addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
        # Ensure that the we fully utilize the minimum amount of resources that are supplied by
        # Fargate https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html
        # Fargate adds 256 MB to each pod's memory reservation for the required Kubernetes
        # components (kubelet, kube-proxy, and containerd). Fargate rounds up to the following
        # compute configuration that most closely matches the sum of vCPU and memory requests in
        # order to ensure pods always have the resources that they need to run.
        resources = {
          limits = {
            cpu = "0.25"
            # We are targeting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
          requests = {
            cpu = "0.25"
            # We are targeting the smallest Task size of 512Mb, so we subtract 256Mb from the
            # request/limit to ensure we can fit within that task
            memory = "256M"
          }
        }
      })
    }
    vpc-cni    = {}
    kube-proxy = {}
  }

  # Enable Karpenter
  enable_karpenter = true

  karpenter = {
    chart_version       = "1.1.2"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  karpenter_node = {
    iam_role_use_name_prefix = false
    iam_role_additional_policies = [
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ]
  }

  tags = local.tags
}

# Allow Karpenter access to the EKS cluster
resource "aws_eks_access_entry" "karpenter_node_access_entry" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.core_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = local.tags
}

################################################################################
# Karpenter manifest
################################################################################
resource "kubectl_manifest" "karpenter" {
  for_each = fileset("${path.module}/karpenter", "*.yaml")

  yaml_body = templatefile("${path.module}/karpenter/${each.key}", {
    cluster_name = module.eks.cluster_name
  })

  depends_on = [module.core_addons]
}

################################################################################
# Additional addons
################################################################################
# We need to wait for the Karpenter manifest to be deployed first
module "additional_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.19"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Install Prometheus and Grafana
  enable_metrics_server        = true
  enable_kube_prometheus_stack = true

  # Disable Prometheus node exporter
  kube_prometheus_stack = {
    values = [
      jsonencode({
        nodeExporter = {
          enabled = false
        },
        alertmanager = {
          enabled = false
        }
      })
    ]
  }

  # Install the nvidia-device-plugin
  helm_releases = {
    nvidia-plugin = {
      repository       = "https://nvidia.github.io/k8s-device-plugin"
      chart            = "nvidia-device-plugin"
      chart_version    = "0.17.0"
      namespace        = "nvidia-device-plugin"
      create_namespace = true
    }

    # This Helm chart configures the KubeRay Operator, which can be used for advanced setups.
    # For instance, serving a model across multiple nodes.
    # For more details: https://github.com/eliran89c/self-hosted-llm-on-eks/multi-node-serving.md 
    # kuberay = {
    #   repository       = "https://ray-project.github.io/kuberay-helm/"
    #   chart            = "kuberay-operator"
    #   version          = "1.1.0"
    #   namespace        = "kuberay-operator"
    #   create_namespace = true
    # }
  }

  tags = local.tags

  depends_on = [kubectl_manifest.karpenter]
}