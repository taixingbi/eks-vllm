#!/usr/bin/env bash
# Apply KEDA ScaledObject for vLLM autoscaling (requires KEDA + Prometheus).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_KEDA}" != "1" ]]; then
  echo "KEDA not enabled. Set DEV_ENABLE_KEDA=1 for dev or use prod."
  exit 1
fi

if [[ "${ENABLE_PROMETHEUS}" != "1" ]]; then
  echo "KEDA requires Prometheus. Set DEV_ENABLE_PROMETHEUS=1 or DEV_ENABLE_KEDA=1 (auto-enables Prometheus)."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"
kubectl apply -f "${OUT_DIR}/vllm/keda-scaledobject.yaml"

echo "KEDA ScaledObject applied (${TF_ENVIRONMENT})."
