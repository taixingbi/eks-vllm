variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "qwen-vllm"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "qwen-vllm-prod"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use single NAT gateway (false for prod HA)"
  type        = bool
  default     = false
}

variable "system_node_instance_types" {
  description = "System node instance types"
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "system_node_desired_size" {
  description = "Desired system nodes"
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum system nodes"
  type        = number
  default     = 4
}

variable "waf_rate_limit" {
  description = "WAF rate-based rule limit (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

variable "waf_managed_rules_action" {
  description = "AWS managed WAF rules action: count (observe) or block"
  type        = string
  default     = "count"
}

variable "assign_public_ipv4_to_nodes" {
  description = "Launch system nodes in public subnets with public IP. Set false (default) for private system nodes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Default tags"
  type        = map(string)
  default = {
    Project     = "qwen-vllm"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
