terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.32.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.12.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.25.2"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

provider "kubernetes" {
  #config_path            = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    #config_path = "~/.kube/config"
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  name = "jira-terraform-vpc"
  cidr = "10.1.0.0/16"

  azs              = ["eu-central-1a", "eu-central-1b"]
  private_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]
  public_subnets   = ["10.1.1.0/24", "10.1.2.0/24"]
  database_subnets = ["10.1.201.0/24", "10.1.202.0/24"]
  intra_subnets    = ["10.1.151.0/24", "10.1.152.0/24"]

  create_database_subnet_group = true

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Terraform   = "true"
    Environment = "test"
  }
}

module "security-group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.1.0"

  name        = "jira-database"
  description = "Jira database security group"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "Database access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.3.1"

  identifier = "jira-database"

  engine               = "postgres"
  engine_version       = "15"
  family               = "postgres15"
  major_engine_version = "15"
  instance_class       = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 50

  db_name  = "jiradb"
  username = "jira"
  password = "Def12345"
  port     = 5432

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security-group.security_group_id]

  backup_retention_period = 0
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "1.4.0"

  name           = "jira-efs"
  creation_token = "jira-efs"

  mount_targets = {
    "eu-central-1a" = { subnet_id = module.vpc.private_subnets[0] }
    "eu-central-1b" = { subnet_id = module.vpc.private_subnets[1] }
  }
  security_group_description = "Jira EFS security group"
  security_group_vpc_id      = module.vpc.vpc_id
  security_group_rules = {
    vpc = {
      description = "NFS ingress from VPC subnets"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.21.0"

  cluster_name    = "jira-cluster"
  cluster_version = "1.28"

  cluster_endpoint_public_access = true

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
    aws-efs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    test = {
      min_size     = 1
      max_size     = 1
      desired_size = 1

      instance_types = ["m5.large"]
      capacity_type  = "SPOT"

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            delete_on_termination = true
          }
        }
      }
    }
  }
}

provider "kubernetes" {
  alias                  = "post-eks"
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
}

data "aws_eks_cluster" "cluster" {
  depends_on = [
    module.eks
  ]
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  depends_on = [
    module.eks
  ]
  name = module.eks.cluster_name
}

data "aws_caller_identity" "current" {
  depends_on = [module.eks]
}

resource "aws_iam_policy" "lb_controller_policy" {
  depends_on = [module.eks]

  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam_policy.json")
}

locals {
  oidc_provider_url = replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")
  oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(local.oidc_provider_url, "https://", "")}"
  db_credentials    = jsondecode(data.aws_secretsmanager_secret_version.db_password.secret_string)
}
/* Used for debugging
output "oidc_provider_url" {
  value = local.oidc_provider_url
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}
*/
resource "aws_iam_role" "lb_controller_role" {
  depends_on = [module.eks]

  name = "AWSLoadBalancerControllerRole"
  assume_role_policy = templatefile("${path.module}/load-balancer-role-trust-policy.json.tpl", {
    oidc_provider_arn = local.oidc_provider_arn
    oidc_provider_url = local.oidc_provider_url
    cluster_name      = module.eks.cluster_name
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller_attach" {
  role       = aws_iam_role.lb_controller_role.name
  policy_arn = aws_iam_policy.lb_controller_policy.arn
}

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  depends_on = [module.eks]
  provider   = kubernetes.post-eks

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.lb_controller_role.arn
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  depends_on = [module.eks]
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
}

resource "kubernetes_secret" "dbcreds" {
  provider = kubernetes.post-eks

  metadata {
    name = "dbcreds"
  }

  data = {
    "username" = "${local.db_credentials["username"]}"
    "password" = "${local.db_credentials["password"]}"
  }
}

resource "kubernetes_persistent_volume" "efs_pv" {
  provider = kubernetes.post-eks
  depends_on = [
    module.eks,
    module.efs
  ]

  metadata {
    name = "efs-pv"
  }

  spec {
    capacity = {
      storage = "5Gi"
    }

    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "gp2"

    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = module.efs.id
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "efs_claim" {
  provider   = kubernetes.post-eks
  depends_on = [kubernetes_persistent_volume.efs_pv]

  metadata {
    name = "efs-claim"
  }

  spec {
    access_modes = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
    volume_name = "efs-pv"
  }
}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = module.rds.db_instance_master_user_secret_arn
}

resource "helm_release" "jira" {
  depends_on = [
    module.eks,
    module.efs,
    module.rds,
    helm_release.aws_lb_controller
  ]

  name       = "jira-application"
  repository = "https://atlassian.github.io/data-center-helm-charts"
  chart      = "jira"

  set {
    name  = "image.repository"
    value = "atlassian/jira-software"
  }

  set {
    name  = "image.tag"
    value = "9.12.1"
  }

  set {
    name  = "database.type"
    value = "postgres72"
  }

  set {
    name  = "database.url"
    value = "jdbc:postgresql://${module.rds.db_instance_endpoint}/${module.rds.db_instance_name}"
  }

  set {
    name  = "database.driver"
    value = "org.postgresql.Driver"
  }

  set {
    name  = "database.credentials.secretName"
    value = "dbcreds"
  }

  set {
    name  = "database.credentials.usernameSecretKey"
    value = "username"
  }

  set {
    name  = "database.credentials.passwordSecretKey"
    value = "password"
  }

  set {
    name  = "ingress.create"
    value = "true"
  }

  set {
    name  = "ingress.className"
    value = "alb"
  }

  set {
    name  = "ingress.nginx"
    value = "false"
  }

  set {
    name  = "ingress.maxBodySize"
    value = "250m"
  }

  set {
    name  = "ingress.proxyConnectTimeout"
    value = "300"
  }

  set {
    name  = "ingress.proxyReadTimeout"
    value = "300"
  }

  set {
    name  = "ingress.proxySendTimeout"
    value = "300"
  }

  set {
    name  = "ingress.host"
    value = ""
  }

  set {
    name  = "ingress.path"
    value = "/"
  }

  set {
    name  = "ingress.annotations.kubernetes\\.io/ingress\\.class"
    value = "alb"
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = "internet-facing"
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
    value = "ip"
  }

  set {
    name  = "ingress.annotations.alb\\.ingress\\.kubernetes\\.io/load-balancer-attributes"
    value = "idle_timeout.timeout_seconds=300"
  }

  set {
    name  = "volumes.sharedHome.persistentVolumeClaim.create"
    value = "false"
  }

  set {
    name  = "ingress.https"
    value = "false"
  }

  set {
    name  = "jira.clustering.enabled"
    value = "false"
  }

  set {
    name  = "volumes.sharedHome.customVolume.persistentVolumeClaim.claimName"
    value = "efs-claim"
  }

  set {
    name  = "jira.resources.container.requests.cpu"
    value = "1"
  }

  set {
    name  = "jira.resources.container.requests.memory"
    value = "4G"
  }

  set {
    name  = "jira.resources.jvm.maxHeap"
    value = "1G"
  }

  set {
    name  = "jira.resources.jvm.minHeap"
    value = "384m"
  }

  set {
    name  = "jira.resources.jvm.reservedCodeCache"
    value = "512m"
  }
}

output "db_password" {
  value     = data.aws_secretsmanager_secret_version.db_password.secret_string
  sensitive = true
}

output "kubernetes_secret_values" {
  value = {
    "username" = base64encode(local.db_credentials["username"])
    "password" = base64encode(local.db_credentials["password"])
  }
  sensitive = true
}

output "url" {
  value     = "jdbc:postgresql://${module.rds.db_instance_endpoint}/${module.rds.db_instance_name}"
  sensitive = true
}
