#!/usr/bin/env bash
# Apply HTTPS ALB Ingress for vLLM (requires ALB Controller + ACM cert).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_ALB}" != "1" ]]; then
  echo "ALB not enabled. Set DEV_ENABLE_ALB=1 for dev or use prod."
  exit 1
fi

if [[ -z "${ACM_CERTIFICATE_ARN:-}" ]]; then
  echo "ACM_CERTIFICATE_ARN is required for HTTPS ingress."
  echo "Set it in the dev/prod GitHub environment or export before running."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"
kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"

echo "Ingress applied (${TF_ENVIRONMENT}, host=${INFERENCE_HOSTNAME:-inference.example.com})."
echo "Wait for ALB: kubectl get ingress vllm-qwen -n vllm -w"
