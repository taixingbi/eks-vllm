variable "name" {
  description = "Prefix for the model artifacts bucket (e.g. qwen-vllm-dev)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used for IRSA role naming)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
