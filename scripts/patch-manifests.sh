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
  KEDA_WAITING_THRESHOLD=2
  KEDA_GPU_CACHE_THRESHOLD=0.80
  KEDA_TTFT_P95_THRESHOLD=2
  KEDA_SCALEUP_STABILIZATION=120
  VLLM_CPU_REQUEST=2
  VLLM_MEMORY_REQUEST=8Gi
  VLLM_CPU_LIMIT=6
  VLLM_MEMORY_LIMIT=16Gi
  VLLM_SHM_SIZE=1Gi
  NODEPOOL_CPU_LIMIT=32
  NODEPOOL_MEMORY_LIMIT=128Gi
  NODEPOOL_CONSOLIDATION_POLICY=WhenEmpty
  NODEPOOL_CONSOLIDATE_AFTER=720h
  ROLLING_MAX_SURGE=0
  ROLLING_MAX_UNAVAILABLE=1
  PDB_MIN_AVAILABLE=0
  VLLM_DTYPE=auto
  VLLM_MAX_MODEL_LEN=2048
  VLLM_GPU_MEMORY_UTIL=0.75
  VLLM_STARTUP_FAILURE_THRESHOLD=90
  PRESTOP_SLEEP_SECONDS=15
  TERMINATION_GRACE_SECONDS=120
else
  VLLM_REPLICAS=2
  KEDA_MIN_REPLICAS=2
  KEDA_WAITING_THRESHOLD=3
  KEDA_GPU_CACHE_THRESHOLD=0.80
  KEDA_TTFT_P95_THRESHOLD=2
  KEDA_SCALEUP_STABILIZATION=120
  VLLM_CPU_REQUEST=2
  VLLM_MEMORY_REQUEST=12Gi
  VLLM_CPU_LIMIT=6
  VLLM_MEMORY_LIMIT=24Gi
  VLLM_SHM_SIZE=2Gi
  NODEPOOL_CPU_LIMIT=64
  NODEPOOL_MEMORY_LIMIT=256Gi
  NODEPOOL_CONSOLIDATION_POLICY=WhenEmptyOrUnderutilized
  NODEPOOL_CONSOLIDATE_AFTER=30m
  ROLLING_MAX_SURGE=1
  ROLLING_MAX_UNAVAILABLE=0
  PDB_MIN_AVAILABLE=1
  VLLM_DTYPE=bfloat16
  VLLM_MAX_MODEL_LEN=8192
  VLLM_GPU_MEMORY_UTIL=0.90
  VLLM_STARTUP_FAILURE_THRESHOLD=30
  PRESTOP_SLEEP_SECONDS=30
  TERMINATION_GRACE_SECONDS=120
fi

# NodePool instance-size follows INSTANCE_TYPE (g5.2xlarge -> "2xlarge", g5.4xlarge -> "4xlarge").
INSTANCE_FAMILY="${INSTANCE_TYPE%%.*}"
INSTANCE_SIZE="${INSTANCE_TYPE#*.}"
KARPENTER_INSTANCE_SIZES="\"${INSTANCE_SIZE}\""

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
    -e "s|__KEDA_WAITING_THRESHOLD__|${KEDA_WAITING_THRESHOLD}|g" \
    -e "s|__KEDA_GPU_CACHE_THRESHOLD__|${KEDA_GPU_CACHE_THRESHOLD}|g" \
    -e "s|__KEDA_TTFT_P95_THRESHOLD__|${KEDA_TTFT_P95_THRESHOLD}|g" \
    -e "s|__KEDA_SCALEUP_STABILIZATION__|${KEDA_SCALEUP_STABILIZATION}|g" \
    -e "s|__PRESTOP_SLEEP_SECONDS__|${PRESTOP_SLEEP_SECONDS}|g" \
    -e "s|__TERMINATION_GRACE_SECONDS__|${TERMINATION_GRACE_SECONDS}|g" \
    -e "s|__NVIDIA_DEVICE_PLUGIN_VERSION__|v${NVIDIA_DEVICE_PLUGIN_VERSION}|g" \
    -e "s|__CLUSTER_NAME_VALUE__|${CLUSTER_NAME}|g" \
    -e "s|__KARPENTER_INSTANCE_SIZES__|${KARPENTER_INSTANCE_SIZES}|g" \
    -e "s|__NODEPOOL_CPU_LIMIT__|${NODEPOOL_CPU_LIMIT}|g" \
    -e "s|__NODEPOOL_MEMORY_LIMIT__|${NODEPOOL_MEMORY_LIMIT}|g" \
    -e "s|__NODEPOOL_CONSOLIDATION_POLICY__|${NODEPOOL_CONSOLIDATION_POLICY}|g" \
    -e "s|__NODEPOOL_CONSOLIDATE_AFTER__|${NODEPOOL_CONSOLIDATE_AFTER}|g" \
    -e "s|__VLLM_CPU_REQUEST__|${VLLM_CPU_REQUEST}|g" \
    -e "s|__VLLM_MEMORY_REQUEST__|${VLLM_MEMORY_REQUEST}|g" \
    -e "s|__VLLM_CPU_LIMIT__|${VLLM_CPU_LIMIT}|g" \
    -e "s|__VLLM_MEMORY_LIMIT__|${VLLM_MEMORY_LIMIT}|g" \
    -e "s|__VLLM_SHM_SIZE__|${VLLM_SHM_SIZE}|g" \
    -e "s|__ROLLING_MAX_SURGE__|${ROLLING_MAX_SURGE}|g" \
    -e "s|__ROLLING_MAX_UNAVAILABLE__|${ROLLING_MAX_UNAVAILABLE}|g" \
    -e "s|__PDB_MIN_AVAILABLE__|${PDB_MIN_AVAILABLE}|g" \
    -e "s|__VLLM_DTYPE__|${VLLM_DTYPE}|g" \
    -e "s|__VLLM_MAX_MODEL_LEN__|${VLLM_MAX_MODEL_LEN}|g" \
    -e "s|__VLLM_GPU_MEMORY_UTIL__|${VLLM_GPU_MEMORY_UTIL}|g" \
    -e "s|__VLLM_STARTUP_FAILURE_THRESHOLD__|${VLLM_STARTUP_FAILURE_THRESHOLD}|g" \
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
cp "${ROOT}/kubernetes/vllm/ingress-http.yaml" "${OUT_DIR}/vllm/"
patch_file "${ROOT}/kubernetes/gpu/nvidia-device-plugin.yaml" "${OUT_DIR}/nvidia-device-plugin.yaml"
cp "${ROOT}/kubernetes/monitoring/namespace.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/servicemonitor.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/prometheus-rules.yaml" "${OUT_DIR}/monitoring/"

echo "Patched manifests written to ${OUT_DIR} (${TF_ENVIRONMENT})"
echo "  MODEL_NAME=${MODEL_NAME}"
echo "  MODEL_PATH=${MODEL_PATH}"
echo "  INSTANCE_TYPE=${INSTANCE_TYPE}"
echo "  KARPENTER_INSTANCE_SIZES=[${KARPENTER_INSTANCE_SIZES}]"
echo "  NODEPOOL_LIMITS=cpu:${NODEPOOL_CPU_LIMIT},memory:${NODEPOOL_MEMORY_LIMIT}"
echo "  VLLM_RESOURCES=cpu:${VLLM_CPU_REQUEST},memory:${VLLM_MEMORY_REQUEST}"
echo "  VLLM_REPLICAS=${VLLM_REPLICAS}"
echo "  KEDA_MIN_REPLICAS=${KEDA_MIN_REPLICAS}"
echo "  KEDA_WAITING_THRESHOLD=${KEDA_WAITING_THRESHOLD}"
