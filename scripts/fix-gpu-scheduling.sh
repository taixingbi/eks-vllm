#!/usr/bin/env bash
# Reset Karpenter GPU state and re-apply patched manifests (recovery without destroy).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

"${ROOT}/scripts/patch-manifests.sh"

echo "Clearing stale GPU nodeclaims..."
kubectl delete nodeclaims -l karpenter.sh/nodepool=g5-ondemand --ignore-not-found --wait=false

echo "Removing stale GPU nodes (disrupted / evicted rollouts)..."
kubectl delete node -l workload=gpu --ignore-not-found --wait=false 2>/dev/null || true

echo "Applying Karpenter + vLLM manifests..."
kubectl apply -f "${OUT_DIR}/karpenter/ec2nodeclass-g5.yaml"
kubectl apply -f "${OUT_DIR}/karpenter/nodepool-g5-ondemand.yaml"
kubectl apply -f "${OUT_DIR}/vllm/deployment.yaml"
# Allow voluntary disruption during recovery; restored from manifest after rollout.
kubectl -n vllm patch pdb vllm-qwen -p '{"spec":{"minAvailable":0}}' --type=merge 2>/dev/null || true
kubectl -n vllm scale deployment vllm-qwen --replicas=1 2>/dev/null || true
kubectl -n vllm delete rs -l app=vllm-qwen --field-selector='status.replicas=0' --ignore-not-found 2>/dev/null || true
kubectl delete pod -n vllm --field-selector=status.phase=Failed --ignore-not-found 2>/dev/null || true

if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  ROLLOUT_TIMEOUT=45m
else
  ROLLOUT_TIMEOUT=20m
fi

echo "Waiting for vLLM rollout (up to ${ROLLOUT_TIMEOUT})..."
kubectl rollout status deployment/vllm-qwen -n vllm --timeout="${ROLLOUT_TIMEOUT}"
echo "Restoring PDB from manifest..."
kubectl apply -f "${OUT_DIR}/vllm/deployment.yaml"
kubectl -n vllm get pods -l app=vllm-qwen -o wide
kubectl get nodes -l workload=gpu 2>/dev/null || true
