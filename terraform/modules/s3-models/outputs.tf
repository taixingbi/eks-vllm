output "bucket_name" {
  description = "S3 bucket name for model artifacts"
  value       = aws_s3_bucket.model_artifacts.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for model artifacts"
  value       = aws_s3_bucket.model_artifacts.arn
}

output "vllm_s3_role_arn" {
  description = "IRSA role ARN for vLLM ServiceAccount (read-only S3 model access)"
  value       = module.vllm_s3_irsa.iam_role_arn
}
