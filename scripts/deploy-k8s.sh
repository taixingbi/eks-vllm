#!/usr/bin/env bash
# Patch manifests and apply Kubernetes resources to the cluster.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"

TMP_SECRETS=$(mktemp)
trap 'rm -f "$TMP_SECRETS"' EXIT
sed "s|qwen-vllm/hf-token|${HF_SECRET_NAME}|g" \
  "${ROOT}/kubernetes/vllm/external-secret-hf.yaml" > "${TMP_SECRETS}"

kubectl apply -f "${ROOT}/kubernetes/vllm/cluster-secret-store.yaml"
kubectl apply -f "${ROOT}/kubernetes/vllm/namespace.yaml"
kubectl apply -f "${TMP_SECRETS}"

kubectl wait --for=condition=Ready clustersecretstore/aws-secrets-manager --timeout=300s 2>/dev/null || true
kubectl wait --for=condition=Ready externalsecret/hf-token -n vllm --timeout=300s 2>/dev/null || true

kubectl apply -f "${OUT_DIR}/karpenter/"
kubectl apply -f "${OUT_DIR}/nvidia-device-plugin.yaml"
kubectl apply -f "${OUT_DIR}/vllm/configmap.yaml"
kubectl apply -f "${OUT_DIR}/vllm/pvc-efs.yaml"

kubectl apply -f "${OUT_DIR}/vllm/model-seed-job.yaml"
if ! kubectl wait --for=condition=complete job/model-seed -n vllm --timeout=3600s 2>/dev/null; then
  echo "model-seed job still running or already completed; continuing"
fi

kubectl apply -f "${OUT_DIR}/vllm/deployment.yaml"
kubectl apply -f "${OUT_DIR}/vllm/service.yaml"

if [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
  kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"
else
  echo "Skipping ingress (set ACM_CERTIFICATE_ARN to enable HTTPS ingress)"
fi

kubectl apply -f "${OUT_DIR}/vllm/keda-scaledobject.yaml"
kubectl apply -f "${OUT_DIR}/monitoring/"

echo "Kubernetes deployment complete (${TF_ENVIRONMENT})."
