.PHONY: bootstrap init plan apply patch install-controllers install-addons install-prometheus install-keda install-alb sync-hf-secret build-image deploy-k8s delete-k8s delete-addons destroy fix-gpu

TF_ENVIRONMENT ?= prod
TF_DIR = terraform/environments/$(TF_ENVIRONMENT)

bootstrap:
	cd terraform/bootstrap && terraform init && terraform apply

init:
	cd $(TF_DIR) && terraform init

plan:
	cd $(TF_DIR) && terraform plan

apply:
	cd $(TF_DIR) && terraform apply

patch:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/patch-manifests.sh

install-controllers:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/install-controllers.sh

install-addons:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/install-addons.sh

# Step 6 on dev: slim Prometheus Helm release + vLLM ServiceMonitor (vLLM should be Running).
install-prometheus:
	DEV_ENABLE_PROMETHEUS=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/install-addons.sh
	DEV_ENABLE_PROMETHEUS=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/apply-monitoring.sh

# Step 7 on dev: KEDA + ScaledObject (also enables Prometheus via env.sh).
install-keda:
	DEV_ENABLE_KEDA=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/install-addons.sh
	DEV_ENABLE_KEDA=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/apply-monitoring.sh
	DEV_ENABLE_KEDA=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/apply-keda.sh

# Step 8 on dev: ALB Controller + Ingress (HTTP: DEV_ALB_HTTP_ONLY=1; HTTPS: ACM secrets).
install-alb:
	DEV_ENABLE_ALB=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/install-alb-controller.sh
	DEV_ENABLE_ALB=1 TF_ENVIRONMENT=$(TF_ENVIRONMENT) \
	  DEV_ALB_HTTP_ONLY="$(DEV_ALB_HTTP_ONLY)" \
	  ACM_CERTIFICATE_ARN="$(ACM_CERTIFICATE_ARN)" \
	  INFERENCE_HOSTNAME="$(INFERENCE_HOSTNAME)" \
	  ./scripts/apply-ingress.sh

sync-hf-secret:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/sync-hf-secret.sh

build-image:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/build-push-image.sh

deploy-k8s:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/deploy-k8s.sh

fix-gpu:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/fix-gpu-scheduling.sh

delete-k8s:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/delete-k8s.sh

delete-addons:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/delete-addons.sh

destroy:
	TF_ENVIRONMENT=$(TF_ENVIRONMENT) ./scripts/destroy.sh

kubeconfig:
	aws eks update-kubeconfig --region us-east-1 --name qwen-vllm-$(TF_ENVIRONMENT)

kubeconfig-prod:
	$(MAKE) kubeconfig TF_ENVIRONMENT=prod

kubeconfig-dev:
	$(MAKE) kubeconfig TF_ENVIRONMENT=dev
