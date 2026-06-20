output "role_arn" {
  description = "External Secrets Operator IRSA role ARN"
  value       = module.external_secrets_irsa.iam_role_arn
}
