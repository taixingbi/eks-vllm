#!/usr/bin/env bash
# Install or upgrade Kong platform gateway (Helm, DB-less).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/helm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_PLATFORM_GATEWAY}" != "1" ]]; then
  echo "Platform gateway not enabled."
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

KONG_CONFIG="${OUT_DIR}/gateway/kong-dbless-config.yaml"
if [[ ! -f "${KONG_CONFIG}" ]]; then
  echo "ERROR: ${KONG_CONFIG} not found — run patch-manifests or build-kong-config first"
  exit 1
fi

helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update

KONG_HELM_ARGS=(
  --namespace vllm
  --create-namespace
  --version "${KONG_CHART_VERSION}"
  --wait
  --timeout 10m
  --set ingressController.enabled=false
  --set manager.enabled=false
  --set replicaCount="${GATEWAY_REPLICAS}"
  --set env.database=off
  --set env.declarative_config=/kong/kong-dbless-config.yaml
  --set env.proxy_read_timeout=300
  --set env.proxy_send_timeout=300
  --set env.proxy_connect_timeout=10
  --set 'env.trusted_ips=0.0.0.0/0\,::/0'
  --set env.real_ip_header=X-Forwarded-For
  --set env.real_ip_recursive=true
  --set proxy.type=ClusterIP
  --set proxy.http.enabled=true
  --set proxy.http.servicePort=8000
  --set proxy.http.containerPort=8000
  --set proxy.tls.enabled=false
  --set resources.requests.cpu="${GATEWAY_CPU_REQUEST}"
  --set resources.requests.memory="${GATEWAY_MEMORY_REQUEST}"
  --set resources.limits.cpu="${GATEWAY_CPU_LIMIT}"
  --set resources.limits.memory="${GATEWAY_MEMORY_LIMIT}"
  --set-file dblessConfig.config="${KONG_CONFIG}"
)

echo "Installing Kong platform gateway (replicas=${GATEWAY_REPLICAS})..."
helm_upgrade_install vllm-platform-gateway kong/kong "${KONG_HELM_ARGS[@]}"

if [[ "${GATEWAY_PDB_MIN_AVAILABLE}" -gt 0 ]]; then
  kubectl apply -f "${OUT_DIR}/gateway/kong-pdb.yaml"
fi

echo "Kong platform gateway installed (release=vllm-platform-gateway, svc=vllm-platform-gateway-kong-proxy)."
