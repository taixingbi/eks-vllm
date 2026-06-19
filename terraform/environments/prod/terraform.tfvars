aws_region                 = "us-east-1"
name_prefix                = "qwen-vllm"
cluster_name               = "qwen-vllm-prod"
cluster_version            = "1.29"
vpc_cidr                   = "10.0.0.0/16"
az_count                   = 2
single_nat_gateway         = false
system_node_desired_size   = 2
system_node_min_size       = 2
system_node_max_size       = 4

tags = {
  Project     = "qwen-vllm"
  Environment = "prod"
  ManagedBy   = "terraform"
}
