variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the cluster control plane"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for node groups when assign_public_ipv4_to_nodes is true"
  type        = list(string)
  default     = []
}

variable "assign_public_ipv4_to_nodes" {
  description = "Launch system and Karpenter nodes in public subnets with a public IPv4 address"
  type        = bool
  default     = true
}

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group"
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "system_node_desired_size" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 4
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
