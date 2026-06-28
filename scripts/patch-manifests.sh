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
MODEL_S3_BUCKET=$(terraform output -raw model_artifacts_bucket_name)
VLLM_MODEL_S3_ROLE_ARN=$(terraform output -raw vllm_model_s3_role_arn)
ACM_CERTIFICATE_ARN="${ACM_CERTIFICATE_ARN:-}"
INFERENCE_HOSTNAME="${INFERENCE_HOSTNAME:-inference.example.com}"

# Dev vLLM tuning: 7B/8B on g5.2xlarge needs conservative limits (32 GiB host RAM, 24 GB VRAM).
dev_model_is_large() {
  local bn="${MODEL_NAME##*/}"
  [[ "${bn}" =~ [78]B ]] || [[ "${bn}" =~ 14B ]] || [[ "${bn}" =~ 32B ]]
}

if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  VLLM_REPLICAS=2
  KEDA_MIN_REPLICAS=2
  KEDA_WAITING_THRESHOLD=2
  KEDA_GPU_CACHE_THRESHOLD=0.80
  KEDA_TTFT_P95_THRESHOLD=2
  KEDA_SCALEUP_STABILIZATION=120
  VLLM_CPU_REQUEST=2
  VLLM_CPU_LIMIT=6
  NODEPOOL_CPU_LIMIT=32
  NODEPOOL_MEMORY_LIMIT=128Gi
  NODEPOOL_CONSOLIDATION_POLICY=WhenEmpty
  NODEPOOL_CONSOLIDATE_AFTER=720h
  ROLLING_MAX_SURGE=0
  ROLLING_MAX_UNAVAILABLE=1
  PDB_MIN_AVAILABLE=1
  PRESTOP_SLEEP_SECONDS=15
  TERMINATION_GRACE_SECONDS=120
  ROUTER_REPLICAS=1
  ROUTER_PDB_MIN_AVAILABLE=0
  ROUTER_CPU_REQUEST=500m
  ROUTER_MEMORY_REQUEST=1Gi
  ROUTER_CPU_LIMIT=1
  ROUTER_MEMORY_LIMIT=2Gi
  ROUTER_PREFIX_MIN_MATCH=32
  LMCACHE_LOG_LEVEL=INFO
  if dev_model_is_large; then
    VLLM_MEMORY_REQUEST=10Gi
    VLLM_MEMORY_LIMIT=20Gi
    VLLM_SHM_SIZE=2Gi
    VLLM_DTYPE=bfloat16
    VLLM_MAX_MODEL_LEN=4096
    VLLM_GPU_MEMORY_UTIL=0.85
    VLLM_STARTUP_FAILURE_THRESHOLD=90
  else
    VLLM_MEMORY_REQUEST=8Gi
    VLLM_MEMORY_LIMIT=16Gi
    VLLM_SHM_SIZE=1Gi
    VLLM_DTYPE=auto
    VLLM_MAX_MODEL_LEN=2048
    VLLM_GPU_MEMORY_UTIL=0.75
    VLLM_STARTUP_FAILURE_THRESHOLD=90
  fi
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
  ROUTER_REPLICAS=2
  ROUTER_PDB_MIN_AVAILABLE=1
  ROUTER_CPU_REQUEST=1
  ROUTER_MEMORY_REQUEST=2Gi
  ROUTER_CPU_LIMIT=2
  ROUTER_MEMORY_LIMIT=4Gi
  ROUTER_PREFIX_MIN_MATCH=64
  LMCACHE_LOG_LEVEL=WARNING
fi

# GPU + system nodes: private subnets only, no public IP (ALB is the only public edge).
KARPENTER_ASSOCIATE_PUBLIC_IP=false
KARPENTER_SUBNET_DISCOVERY_TAG_KEY="karpenter.sh/discovery-private"

if [[ "${ENABLE_PLATFORM_GATEWAY}" == "1" ]]; then
  INGRESS_BACKEND_SERVICE=vllm-platform-gateway-kong-proxy
elif [[ "${ENABLE_ROUTER}" == "1" ]]; then
  INGRESS_BACKEND_SERVICE=vllm-router
else
  INGRESS_BACKEND_SERVICE=vllm-qwen
fi

if [[ "${ENABLE_WAF}" == "1" ]]; then
  WAF_WEB_ACL_ARN=$(terraform output -raw waf_web_acl_arn)
  WAF_INGRESS_ANNOTATIONS="    alb.ingress.kubernetes.io/wafv2-acl-arn: ${WAF_WEB_ACL_ARN}"
else
  WAF_INGRESS_ANNOTATIONS=""
fi

if [[ "${ENABLE_LMCACHE}" == "1" ]]; then
  ROUTER_LMCACHE_ARGS=$'            - "--lmcache-controller-port"\n            - "9000"'
else
  ROUTER_LMCACHE_ARGS=""
fi

case "${ROUTER_ROUTING_LOGIC}" in
  prefixaware|kvaware)
    ROUTER_OPTIONAL_ARGS=$'            - "--request-stats-window"\n            - "60"\n            - "--prefix-min-match-length"\n            - "__ROUTER_PREFIX_MIN_MATCH__"'
    ROUTER_OPTIONAL_ARGS="${ROUTER_OPTIONAL_ARGS//__ROUTER_PREFIX_MIN_MATCH__/${ROUTER_PREFIX_MIN_MATCH}}"
    ;;
  *)
    ROUTER_OPTIONAL_ARGS=""
    ;;
esac

# Phase 5: verbose routing logs on dev for debugging.
if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  ROUTER_EXTRA_ARGS=""
else
  ROUTER_EXTRA_ARGS=""
fi

ROUTER_IMAGE="${VLLM_ROUTER_REPOSITORY}:${VLLM_ROUTER_TAG}"
INSTANCE_FAMILY="${INSTANCE_TYPE%%.*}"
INSTANCE_SIZE="${INSTANCE_TYPE#*.}"
KARPENTER_INSTANCE_SIZES="\"${INSTANCE_SIZE}\""

mkdir -p "${OUT_DIR}/karpenter" "${OUT_DIR}/vllm" "${OUT_DIR}/monitoring" "${OUT_DIR}/gateway"

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
    -e "s|__MODEL_VERSION_VALUE__|${MODEL_VERSION}|g" \
    -e "s|__MODEL_S3_BUCKET__|${MODEL_S3_BUCKET}|g" \
    -e "s|__MODEL_S3_PREFIX__|${MODEL_S3_PREFIX}|g" \
    -e "s|__VLLM_MODEL_S3_ROLE_ARN__|${VLLM_MODEL_S3_ROLE_ARN}|g" \
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
    -e "s|__KARPENTER_ASSOCIATE_PUBLIC_IP__|${KARPENTER_ASSOCIATE_PUBLIC_IP}|g" \
    -e "s|__KARPENTER_SUBNET_DISCOVERY_TAG_KEY__|${KARPENTER_SUBNET_DISCOVERY_TAG_KEY}|g" \
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
    -e "s|__ROUTER_IMAGE__|${ROUTER_IMAGE}|g" \
    -e "s|__ROUTER_REPLICAS__|${ROUTER_REPLICAS}|g" \
    -e "s|__ROUTER_PDB_MIN_AVAILABLE__|${ROUTER_PDB_MIN_AVAILABLE}|g" \
    -e "s|__ROUTER_ROUTING_LOGIC__|${ROUTER_ROUTING_LOGIC}|g" \
    -e "s|__ROUTER_SESSION_KEY__|${ROUTER_SESSION_KEY}|g" \
    -e "s|__ROUTER_PREFIX_MIN_MATCH__|${ROUTER_PREFIX_MIN_MATCH}|g" \
    -e "s|__ROUTER_CPU_REQUEST__|${ROUTER_CPU_REQUEST}|g" \
    -e "s|__ROUTER_MEMORY_REQUEST__|${ROUTER_MEMORY_REQUEST}|g" \
    -e "s|__ROUTER_CPU_LIMIT__|${ROUTER_CPU_LIMIT}|g" \
    -e "s|__ROUTER_MEMORY_LIMIT__|${ROUTER_MEMORY_LIMIT}|g" \
    -e "s|__LMCACHE_LOG_LEVEL__|${LMCACHE_LOG_LEVEL}|g" \
    -e "s|__INGRESS_BACKEND_SERVICE__|${INGRESS_BACKEND_SERVICE}|g" \
    -e "s|INSTANCE_FAMILY|${INSTANCE_FAMILY}|g" \
    "$src" > "$dst"
}

patch_ingress() {
  local src=$1
  local dst=$2
  sed \
    -e "s|ACM_CERTIFICATE_ARN|${ACM_CERTIFICATE_ARN}|g" \
    -e "s|inference.example.com|${INFERENCE_HOSTNAME}|g" \
    -e "s|__INGRESS_BACKEND_SERVICE__|${INGRESS_BACKEND_SERVICE}|g" \
    -e "s|__WAF_INGRESS_ANNOTATIONS__|${WAF_INGRESS_ANNOTATIONS}|g" \
    "$src" > "$dst"
}

patch_ingress_http() {
  local src=$1
  local dst=$2
  sed \
    -e "s|__INGRESS_BACKEND_SERVICE__|${INGRESS_BACKEND_SERVICE}|g" \
    -e "s|__WAF_INGRESS_ANNOTATIONS__|${WAF_INGRESS_ANNOTATIONS}|g" \
    "$src" > "$dst"
}

apply_lmcache_deployment_blocks() {
  local dst="${OUT_DIR}/vllm/deployment.yaml"
  python3 - "${dst}" "${ENABLE_LMCACHE}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
enabled = sys.argv[2] == "1"
text = path.read_text()

if enabled:
    ports = """            - name: lmcache-worker
              containerPort: 8001
              protocol: TCP
            - name: lmcache-controller
              containerPort: 9000
              protocol: TCP"""
    env = """            - name: LMCACHE_USE_EXPERIMENTAL
              value: "True"
            - name: LMCACHE_CONFIG_FILE
              value: "/etc/lmcache/lmcache.yaml"
            - name: LMCACHE_CONTROLLER_PORT
              value: "9000"
            - name: LMCACHE_WORKER_PORT
              value: "8001"
"""
    volume_mounts = """            - name: lmcache-config
              mountPath: /etc/lmcache
              readOnly: true"""
    volumes = """        - name: lmcache-config
          configMap:
            name: lmcache-config"""
else:
    ports = env = volume_mounts = volumes = ""

for key, val in (
    ("__LMCACHE_PORTS__", ports),
    ("__LMCACHE_ENV__", env),
    ("__LMCACHE_VOLUME_MOUNTS__", volume_mounts),
    ("__LMCACHE_VOLUMES__", volumes),
):
    text = text.replace(key, val)
path.write_text(text)
PY
}

apply_router_multiline_args() {
  local dst="${OUT_DIR}/vllm/router.yaml"
  python3 - "${dst}" "${ROUTER_LMCACHE_ARGS}" "${ROUTER_EXTRA_ARGS}" "${ROUTER_OPTIONAL_ARGS}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lmcache_args = sys.argv[2]
extra_args = sys.argv[3]
optional_args = sys.argv[4]
text = path.read_text()
text = text.replace("__ROUTER_LMCACHE_ARGS__", lmcache_args)
text = text.replace("__ROUTER_EXTRA_ARGS__", extra_args)
text = text.replace("__ROUTER_OPTIONAL_ARGS__", optional_args)
path.write_text(text)
PY
}

patch_file "${ROOT}/kubernetes/karpenter/ec2nodeclass-g5.yaml" "${OUT_DIR}/karpenter/ec2nodeclass-g5.yaml"
patch_file "${ROOT}/kubernetes/karpenter/nodepool-g5-ondemand.yaml" "${OUT_DIR}/karpenter/nodepool-g5-ondemand.yaml"
patch_file "${ROOT}/kubernetes/karpenter/nodepool-g5-spot.yaml" "${OUT_DIR}/karpenter/nodepool-g5-spot.yaml"

patch_file "${ROOT}/kubernetes/vllm/pvc-efs.yaml" "${OUT_DIR}/vllm/pvc-efs.yaml"
patch_file "${ROOT}/kubernetes/vllm/serviceaccount.yaml" "${OUT_DIR}/vllm/serviceaccount.yaml"
patch_file "${ROOT}/kubernetes/vllm/deployment.yaml" "${OUT_DIR}/vllm/deployment.yaml"
apply_lmcache_deployment_blocks
patch_file "${ROOT}/kubernetes/vllm/router.yaml" "${OUT_DIR}/vllm/router.yaml"
apply_router_multiline_args
patch_file "${ROOT}/kubernetes/vllm/configmap.yaml" "${OUT_DIR}/vllm/configmap.yaml"
patch_file "${ROOT}/kubernetes/vllm/model-seed-job.yaml" "${OUT_DIR}/vllm/model-seed-job.yaml"
patch_ingress "${ROOT}/kubernetes/vllm/ingress.yaml" "${OUT_DIR}/vllm/ingress.yaml"
patch_ingress_http "${ROOT}/kubernetes/vllm/ingress-http.yaml" "${OUT_DIR}/vllm/ingress-http.yaml"
patch_file "${ROOT}/kubernetes/vllm/keda-scaledobject.yaml" "${OUT_DIR}/vllm/keda-scaledobject.yaml"
patch_file "${ROOT}/kubernetes/monitoring/cloudwatch-agent.yaml" "${OUT_DIR}/monitoring/cloudwatch-agent.yaml"

if [[ "${ENABLE_PLATFORM_GATEWAY}" == "1" ]]; then
  "${ROOT}/scripts/build-kong-config.sh" "${OUT_DIR}/gateway/kong-dbless-config.yaml"
  sed \
    -e "s|__GATEWAY_PDB_MIN_AVAILABLE__|${GATEWAY_PDB_MIN_AVAILABLE}|g" \
    "${ROOT}/kubernetes/gateway/kong-pdb.yaml" > "${OUT_DIR}/gateway/kong-pdb.yaml"
fi

cp "${ROOT}/kubernetes/vllm/namespace.yaml" "${OUT_DIR}/vllm/"
cp "${ROOT}/kubernetes/vllm/router-rbac.yaml" "${OUT_DIR}/vllm/"
cp "${ROOT}/kubernetes/vllm/lmcache-config.yaml" "${OUT_DIR}/vllm/"
cp "${ROOT}/kubernetes/vllm/service.yaml" "${OUT_DIR}/vllm/"
patch_file "${ROOT}/kubernetes/gpu/nvidia-device-plugin.yaml" "${OUT_DIR}/nvidia-device-plugin.yaml"
cp "${ROOT}/kubernetes/monitoring/namespace.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/servicemonitor.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/servicemonitor-router.yaml" "${OUT_DIR}/monitoring/"
cp "${ROOT}/kubernetes/monitoring/prometheus-rules.yaml" "${OUT_DIR}/monitoring/"

echo "Patched manifests written to ${OUT_DIR} (${TF_ENVIRONMENT})"
echo "  MODEL_NAME=${MODEL_NAME}"
echo "  MODEL_VERSION=${MODEL_VERSION}"
echo "  MODEL_PATH=${MODEL_PATH}"
echo "  MODEL_S3=s3://${MODEL_S3_BUCKET}/${MODEL_S3_PREFIX}"
echo "  INSTANCE_TYPE=${INSTANCE_TYPE}"
echo "  KARPENTER_INSTANCE_SIZES=[${KARPENTER_INSTANCE_SIZES}]"
echo "  KARPENTER_GPU_PUBLIC_IP=${KARPENTER_ASSOCIATE_PUBLIC_IP} subnet_tag=${KARPENTER_SUBNET_DISCOVERY_TAG_KEY}"
echo "  NODEPOOL_LIMITS=cpu:${NODEPOOL_CPU_LIMIT},memory:${NODEPOOL_MEMORY_LIMIT}"
echo "  VLLM_RESOURCES=cpu:${VLLM_CPU_REQUEST},memory:${VLLM_MEMORY_REQUEST}"
echo "  VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN}"
echo "  VLLM_GPU_MEMORY_UTIL=${VLLM_GPU_MEMORY_UTIL}"
echo "  VLLM_DTYPE=${VLLM_DTYPE}"
echo "  VLLM_REPLICAS=${VLLM_REPLICAS}"
echo "  KEDA_MIN_REPLICAS=${KEDA_MIN_REPLICAS}"
echo "  KEDA_WAITING_THRESHOLD=${KEDA_WAITING_THRESHOLD}"
echo "  ENABLE_ROUTER=${ENABLE_ROUTER}"
echo "  ROUTER_ROUTING_LOGIC=${ROUTER_ROUTING_LOGIC}"
echo "  ENABLE_LMCACHE=${ENABLE_LMCACHE}"
echo "  INGRESS_BACKEND=${INGRESS_BACKEND_SERVICE}"
echo "  ENABLE_PLATFORM_GATEWAY=${ENABLE_PLATFORM_GATEWAY}"
echo "  ENABLE_WAF=${ENABLE_WAF}"
