.PHONY: bootstrap init plan apply patch

bootstrap:
	cd terraform/bootstrap && terraform init && terraform apply

init:
	cd terraform/environments/prod && terraform init

plan:
	cd terraform/environments/prod && terraform plan

apply:
	cd terraform/environments/prod && terraform apply

patch:
	./scripts/patch-manifests.sh

kubeconfig:
	aws eks update-kubeconfig --region us-east-1 --name qwen-vllm-prod

build-image:
	@ECR_URL=$$(cd terraform/environments/prod && terraform output -raw ecr_repository_url); \
	aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $${ECR_URL%%/*}; \
	docker build -t $$ECR_URL:v0.8.4 -f docker/Dockerfile.vllm .; \
	docker push $$ECR_URL:v0.8.4
