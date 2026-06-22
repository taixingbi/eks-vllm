#!/usr/bin/env bash
# Apply vLLM ServiceMonitor, PrometheusRules, and CloudWatch agent manifests.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_PROMETHEUS}" != "1" ]]; then
  echo "Prometheus not enabled. Set DEV_ENABLE_PROMETHEUS=1 for dev or use prod."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"
kubectl apply -f "${OUT_DIR}/monitoring/"

echo "Monitoring manifests applied (${TF_ENVIRONMENT})."
