aws_region               = "us-east-1"
name_prefix              = "qwen-vllm-dev"
cluster_name             = "qwen-vllm-dev"
cluster_version          = "1.31"
vpc_cidr                 = "10.1.0.0/16"
az_count                 = 2
single_nat_gateway           = true
system_node_instance_types   = ["m6i.xlarge"]
system_node_desired_size     = 1
system_node_min_size     = 1
system_node_max_size     = 2

tags = {
  Project     = "qwen-vllm"
  Environment = "dev"
  ManagedBy   = "terraform"
}
