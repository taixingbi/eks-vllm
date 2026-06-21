data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  name         = var.name_prefix
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
  cluster_name = var.cluster_name
  single_nat_gateway = var.single_nat_gateway

  tags = var.tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  system_node_instance_types = var.system_node_instance_types
  system_node_desired_size   = var.system_node_desired_size
  system_node_min_size       = var.system_node_min_size
  system_node_max_size       = var.system_node_max_size

  tags = var.tags
}

module "efs" {
  source = "../../modules/efs"

  name                       = "${var.name_prefix}-models"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.node_security_group_id]

  tags = var.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name = "${var.name_prefix}-vllm"

  tags = var.tags
}

module "alb_controller" {
  source = "../../modules/alb-controller"

  cluster_name      = module.eks.cluster_name
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider

  tags = var.tags
}

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  oidc_provider     = module.eks.oidc_provider

  tags = var.tags
}

module "external_secrets" {
  source = "../../modules/external-secrets"

  cluster_name                  = module.eks.cluster_name
  oidc_provider_arn             = module.eks.cluster_oidc_provider_arn
  secrets_manager_secret_prefix = "qwen-vllm-dev/"

  tags = var.tags
}
