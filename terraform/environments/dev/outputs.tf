output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Cluster CA data"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "availability_zones" {
  description = "AZs in use"
  value       = module.vpc.azs
}

output "efs_file_system_id" {
  description = "EFS file system ID for model cache"
  value       = module.efs.file_system_id
}

output "efs_access_point_id" {
  description = "EFS access point ID"
  value       = module.efs.access_point_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for vLLM image"
  value       = module.ecr.repository_url
}

output "karpenter_node_role_arn" {
  description = "Karpenter node IAM role ARN"
  value       = module.karpenter.node_role_arn
}

output "karpenter_instance_profile_name" {
  description = "Karpenter instance profile name"
  value       = module.karpenter.instance_profile_name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue for Spot interruption handling"
  value       = module.karpenter.interruption_queue_name
}

output "alb_controller_role_arn" {
  description = "ALB controller IRSA role ARN"
  value       = module.alb_controller.role_arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  value       = module.karpenter.controller_role_arn
}

output "cloudwatch_agent_role_arn" {
  description = "CloudWatch agent IRSA role ARN"
  value       = module.eks.cloudwatch_agent_role_arn
}

output "efs_csi_role_arn" {
  description = "EFS CSI driver IRSA role ARN"
  value       = module.eks.efs_csi_role_arn
}

output "external_secrets_role_arn" {
  description = "External Secrets Operator IRSA role ARN"
  value       = module.external_secrets.role_arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
