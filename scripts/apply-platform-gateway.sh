#!/usr/bin/env bash
# Apply Kong platform gateway (phase 11). Requires router Running.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_PLATFORM_GATEWAY}" != "1" ]]; then
  echo "Platform gateway not enabled. Set DEV_ENABLE_PLATFORM_GATEWAY=1 for dev or use prod with ALB."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"

if [[ "${TF_ENVIRONMENT}" != "dev" ]]; then
  kubectl apply -f "${ROOT}/kubernetes/vllm/cluster-secret-store.yaml"
  kubectl apply -f "${ROOT}/kubernetes/gateway/external-secret-api-keys.yaml"
  kubectl wait --for=condition=Ready externalsecret/platform-gateway-keys -n vllm --timeout=300s 2>/dev/null || {
    echo "Warning: platform-gateway-keys ExternalSecret not Ready"
  }
  KEYS_JSON=$(kubectl get secret platform-gateway-keys -n vllm -o jsonpath='{.data.keys}' 2>/dev/null | base64 -d || true)
  if [[ -n "${KEYS_JSON}" ]]; then
    mapfile -t KEYS < <(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('\n'.join(d.get('keys',[])))" "${KEYS_JSON}")
    "${ROOT}/scripts/build-kong-config.sh" "${OUT_DIR}/gateway/kong-dbless-config.yaml" "${KEYS[@]}"
  fi
fi

"${ROOT}/scripts/install-platform-gateway.sh"

if [[ "${ENABLE_ALB}" == "1" ]]; then
  if [[ "${ALB_HTTP_ONLY}" == "1" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress-http.yaml"
  elif [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"
  fi
fi

echo "Platform gateway applied (${TF_ENVIRONMENT})."
echo "  ALB backend: vllm-platform-gateway-kong-proxy:8000"
echo "  Headers: X-API-Key or Authorization: Bearer <key>"
