#!/usr/bin/env bash
# Reset Karpenter GPU state and re-apply patched manifests (dev recovery).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

"${ROOT}/scripts/patch-manifests.sh"

echo "Clearing stale GPU nodeclaims..."
kubectl delete nodeclaims -l karpenter.sh/nodepool=g5-ondemand --ignore-not-found --wait=false

echo "Applying Karpenter + vLLM manifests..."
kubectl apply -f "${OUT_DIR}/karpenter/nodepool-g5-ondemand.yaml"
kubectl -n vllm patch pdb vllm-qwen -p '{"spec":{"minAvailable":0}}' --type=merge 2>/dev/null || true
kubectl -n vllm scale deployment vllm-qwen --replicas=1 2>/dev/null || true
kubectl apply -f "${OUT_DIR}/vllm/deployment.yaml"
kubectl -n vllm delete rs -l app=vllm-qwen --field-selector='status.replicas=0' --ignore-not-found 2>/dev/null || true

echo "Waiting for vLLM rollout (up to 20m)..."
kubectl rollout status deployment/vllm-qwen -n vllm --timeout=20m
kubectl -n vllm get pods -l app=vllm-qwen -o wide
