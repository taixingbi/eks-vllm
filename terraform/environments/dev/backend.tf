terraform {
  backend "s3" {
    bucket         = "qwen-vllm-terraform-state"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "qwen-vllm-terraform-locks"
  }
}
