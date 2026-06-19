output "role_arn" {
  description = "ALB controller IRSA role ARN"
  value       = module.alb_controller_irsa.iam_role_arn
}
