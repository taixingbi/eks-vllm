#!/usr/bin/env bash
# Patch Kubernetes manifest placeholders from Terraform outputs.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

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
ACM_CERTIFICATE_ARN="${ACM_CERTIFICATE_ARN:-}"
INFERENCE_HOSTNAME="${INFERENCE_HOSTNAME:-inference.example.com}"

if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  VLLM_REPLICAS=1
  KEDA_MIN_REPLICAS=1
  KARPENTER_INSTANCE_SIZES='"2xlarge", "4xlarge"'
else
  VLLM_REPLICAS=2
  KEDA_MIN_REPLICAS=2
  KARPENTER_INSTANCE_SIZES='"4xlarge"'
fi

mkdir -p "${OUT_DIR}/karpenter" "${OUT_DIR}/vllm" "${OUT_DIR}/monitoring"

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
    -e "s|__MODEL_ID_VALUE__|${MODEL_NAME}|g" \
    -e "s|__MODEL_PATH_VALUE__|${MODEL_PATH}|g" \
    -e "s|__VLLM_REPLICAS__|${VLLM_REPLICAS}|g" \
    -e "s|__KEDA_MIN_REPLICAS__|${KEDA_MIN_REPLICAS}|g" \
    -e "s|__CLUSTER_NAME_VALUE__|${CLUSTER_NAME}|g" \
    -e "s|__KARPENTER_INSTANCE_SIZES__|${KARPENTER_INSTANCE_SIZES}|g" \
    -e "s|INSTANCE_FAMILY|${INSTANCE_FAMILY}|g" \
    "$src" > "$dst"
}

patch_ingress() {
  local src=$1
  local dst=$2
  sed \
    -e "s|ACM_CERTIFICATE_ARN|${ACM_CERTIFICATE_ARN}|g" \
    -e "s|inference.example.com|${INFERENCE_HOSTNAME}|g" \
    "$src" > "$dst"
}

patch_file "${ROOT}/kubernetes/karpenter/ec2nodeclass-g5.yaml" "${OUT_DIR}/karpenter/ec2nodeclass-g5.yaml"
patch_file "${ROOT}/kubernetes/karpenter/nodepool-g5-ondemand.yaml" "${OUT_DIR}/karpenter/nodepool-g5-ondemand.yaml"
patch_file "${ROOT}/kubernetes/karpenter/nodepool-g5-spot.yaml" "${OUT_DIR}/karpenter/nodepool-g5-spot.yaml"

patch_file "${ROOT}/kubernetes/vllm/pvc-efs.yaml" "${OUT_DIR}/vllm/pvc-efs.yaml"
patch_file "${ROOT}/kubernetes/vllm/deployment.yaml" "${OUT_DIR}/vllm/deployment.yaml"
patch_file "${ROOT}/kubernetes/vllm/configmap.yaml" "${OUT_DIR}/vllm/configmap.yaml"
patch_file "${ROOT}/kubernetes/vllm/model-seed-job.yaml" "${OUT_DIR}/vllm/model-seed-job.yaml"
patch_ingress "${ROOT}/kubernetes/vllm/ingress.yaml" "${OUT_DIR}/vllm/ingress.yaml"
patch_file "${ROOT}/kubernetes/vllm/keda-scaledobject.yaml" "${OUT_DIR}/vllm/keda-scaledobject.yaml"
patch_file "${ROOT}/kubernetes/monitoring/cloudwatch-agent.yaml" "${OUT_DIR}/monitoring/cloudwatch-agent.yaml"

cp "${ROOT}/kubernetes/vllm/namespace.yaml" "${OUT_DIR}/vllm/"
cp "${ROOT}/kubernetes/vllm/service.yaml" "${OUT_DIR}/vllm/"
cp "${ROOT}/kubernetes/gpu/nvidia-device-plugin.yaml" "${OUT_DIR}/"
cp "${ROOT}/kubernetes/monitoring/namespace.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/servicemonitor.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/prometheus-rules.yaml" "${OUT_DIR}/monitoring/"

echo "Patched manifests written to ${OUT_DIR} (${TF_ENVIRONMENT})"
echo "  MODEL_NAME=${MODEL_NAME}"
echo "  MODEL_PATH=${MODEL_PATH}"
echo "  INSTANCE_TYPE=${INSTANCE_TYPE}"
echo "  KARPENTER_INSTANCE_SIZES=[${KARPENTER_INSTANCE_SIZES}]"
echo "  VLLM_REPLICAS=${VLLM_REPLICAS}"
echo "  KEDA_MIN_REPLICAS=${KEDA_MIN_REPLICAS}"
