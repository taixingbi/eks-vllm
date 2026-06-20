variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "secrets_manager_secret_prefix" {
  description = "Secrets Manager name prefix this role may read, with trailing slash (e.g. qwen-vllm/)"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
