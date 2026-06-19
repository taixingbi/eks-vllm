#!/usr/bin/env bash
# Patch Kubernetes manifest placeholders from Terraform outputs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform/environments/prod"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required"
  exit 1
fi

cd "$TF_DIR"

CLUSTER_NAME=$(terraform output -raw cluster_name)
NODE_ROLE_ARN=$(terraform output -raw karpenter_node_role_arn)
NODE_ROLE_NAME="${NODE_ROLE_ARN##*/}"
EFS_FS_ID=$(terraform output -raw efs_file_system_id)
EFS_AP_ID=$(terraform output -raw efs_access_point_id)
ECR_URL=$(terraform output -raw ecr_repository_url)
CW_ROLE_ARN=$(terraform output -raw cloudwatch_agent_role_arn)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

patch_file() {
  local src=$1
  local dst=$2
  sed \
    -e "s|CLUSTER_NAME|${CLUSTER_NAME}|g" \
    -e "s|KARPENTER_NODE_ROLE_NAME|${NODE_ROLE_NAME}|g" \
    -e "s|FILE_SYSTEM_ID|${EFS_FS_ID}|g" \
    -e "s|ACCESS_POINT_ID|${EFS_AP_ID}|g" \
    -e "s|ECR_REPOSITORY_URL|${ECR_URL}|g" \
    -e "s|CLOUDWATCH_AGENT_ROLE_ARN|${CW_ROLE_ARN}|g" \
    "$src" > "$dst"
}

mkdir -p "${TMP}/karpenter" "${TMP}/vllm" "${TMP}/monitoring"

patch_file "${ROOT}/kubernetes/karpenter/ec2nodeclass-g5.yaml" "${TMP}/karpenter/ec2nodeclass-g5.yaml"
cp "${ROOT}/kubernetes/karpenter/nodepool-g5-ondemand.yaml" "${TMP}/karpenter/"
cp "${ROOT}/kubernetes/karpenter/nodepool-g5-spot.yaml" "${TMP}/karpenter/"

patch_file "${ROOT}/kubernetes/vllm/pvc-efs.yaml" "${TMP}/vllm/pvc-efs.yaml"
patch_file "${ROOT}/kubernetes/vllm/deployment.yaml" "${TMP}/vllm/deployment.yaml"
patch_file "${ROOT}/kubernetes/monitoring/cloudwatch-agent.yaml" "${TMP}/monitoring/cloudwatch-agent.yaml"

cp "${ROOT}/kubernetes/vllm/namespace.yaml" "${TMP}/vllm/"
cp "${ROOT}/kubernetes/vllm/configmap.yaml" "${TMP}/vllm/"
cp "${ROOT}/kubernetes/vllm/service.yaml" "${TMP}/vllm/"
cp "${ROOT}/kubernetes/vllm/ingress.yaml" "${TMP}/vllm/"
cp "${ROOT}/kubernetes/vllm/keda-scaledobject.yaml" "${TMP}/vllm/"
cp "${ROOT}/kubernetes/gpu/nvidia-device-plugin.yaml" "${TMP}/"
cp "${ROOT}/kubernetes/monitoring/namespace.yaml" "${TMP}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/servicemonitor.yaml" "${TMP}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/prometheus-rules.yaml" "${TMP}/monitoring/"

echo "Patched manifests written to ${TMP}"
echo "Apply with:"
echo "  kubectl apply -f ${TMP}/karpenter/"
echo "  kubectl apply -f ${TMP}/nvidia-device-plugin.yaml"
echo "  kubectl apply -f ${TMP}/vllm/"
echo "  kubectl apply -f ${TMP}/monitoring/"
