variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "secrets_manager_secret_prefix" {
  description = "Prefix for Secrets Manager secrets this role may read (e.g. qwen-vllm-dev)"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
