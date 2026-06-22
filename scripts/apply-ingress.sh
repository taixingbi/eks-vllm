#!/usr/bin/env bash
# Apply ALB Ingress for vLLM (HTTP on dev, or HTTPS when ACM cert is set).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_ALB}" != "1" ]]; then
  echo "ALB not enabled. Set DEV_ENABLE_ALB=1 for dev or use prod."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"

if [[ "${ALB_HTTP_ONLY}" == "1" ]]; then
  echo "Applying HTTP-only ALB Ingress (port 80, no ACM)..."
  kubectl apply -f "${OUT_DIR}/vllm/ingress-http.yaml"
  echo "Ingress applied (${TF_ENVIRONMENT}, HTTP)."
  echo "Wait for ALB: kubectl get ingress vllm-qwen -n vllm -w"
  echo "Then: curl http://\$(kubectl get ingress vllm-qwen -n vllm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/v1/models"
  exit 0
fi

if [[ -z "${ACM_CERTIFICATE_ARN:-}" ]]; then
  echo "ACM_CERTIFICATE_ARN is required for HTTPS ingress."
  echo "For dev without a cert, set DEV_ALB_HTTP_ONLY=1 (HTTP on port 80, use ALB DNS name)."
  exit 1
fi

echo "Applying HTTPS ALB Ingress..."
kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"
echo "Ingress applied (${TF_ENVIRONMENT}, host=${INFERENCE_HOSTNAME:-inference.example.com})."
echo "Wait for ALB: kubectl get ingress vllm-qwen -n vllm -w"
