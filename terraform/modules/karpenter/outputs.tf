output "node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name for Karpenter-provisioned nodes"
  value       = aws_iam_role.node.name
}

output "instance_profile_name" {
  description = "Instance profile for Karpenter nodes"
  value       = aws_iam_instance_profile.node.name
}

output "interruption_queue_name" {
  description = "SQS queue name for Spot interruptions"
  value       = aws_sqs_queue.interruption.name
}

output "interruption_queue_arn" {
  description = "SQS queue ARN for Spot interruptions"
  value       = aws_sqs_queue.interruption.arn
}

output "controller_role_arn" {
  description = "Karpenter controller IRSA role ARN"
  value       = module.karpenter_irsa.iam_role_arn
}
