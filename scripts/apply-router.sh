#!/usr/bin/env bash
# Apply vLLM session/KV-aware router (Gateway phases 1–9). Requires vLLM Deployment Running.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_ROUTER}" != "1" ]]; then
  echo "Router not enabled. Set DEV_ENABLE_ROUTER=1 for dev or use prod."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"

if [[ "${ENABLE_LMCACHE}" == "1" ]]; then
  kubectl apply -f "${OUT_DIR}/vllm/lmcache-config.yaml"
fi

kubectl apply -f "${OUT_DIR}/vllm/router-rbac.yaml"
kubectl apply -f "${OUT_DIR}/vllm/router.yaml"
kubectl rollout status deployment/vllm-router -n vllm --timeout=300s

if [[ "${ENABLE_PROMETHEUS}" == "1" ]]; then
  kubectl apply -f "${OUT_DIR}/monitoring/servicemonitor-router.yaml"
fi

if [[ "${ENABLE_ALB}" == "1" ]]; then
  if [[ "${ALB_HTTP_ONLY}" == "1" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress-http.yaml"
  elif [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"
  fi
fi

echo "Gateway router applied (${TF_ENVIRONMENT}, routing=${ROUTER_ROUTING_LOGIC}, lmcache=${ENABLE_LMCACHE})."
echo "  Client header: ${ROUTER_SESSION_KEY}: <user-or-chat-id>"
echo "  Port-forward: kubectl port-forward -n vllm svc/vllm-router 8000:8000"
