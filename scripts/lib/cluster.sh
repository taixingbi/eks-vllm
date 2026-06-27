#!/usr/bin/env bash
# Resolve EKS cluster name and configure kubectl for the selected environment.
set -euo pipefail

default_cluster_name() {
  echo "qwen-vllm-${TF_ENVIRONMENT}"
}

terraform_init_if_needed() {
  if [[ ! -d "${TF_DIR}/.terraform" ]]; then
    terraform -chdir="${TF_DIR}" init -input=false >/dev/null
  fi
}

resolve_cluster_name() {
  local name=""

  if command -v terraform >/dev/null 2>&1; then
    terraform_init_if_needed 2>/dev/null || true
    name=$(terraform -chdir="${TF_DIR}" output -raw cluster_name 2>/dev/null || true)
  fi

  if [[ -z "${name}" ]]; then
    name="$(default_cluster_name)"
  fi

  echo "${name}"
}

cluster_exists() {
  local cluster_name=$1
  aws eks describe-cluster \
    --region "${AWS_REGION:-us-east-1}" \
    --name "${cluster_name}" \
    >/dev/null 2>&1
}

configure_kubectl() {
  local cluster_name
  cluster_name="$(resolve_cluster_name)"

  if ! cluster_exists "${cluster_name}"; then
    echo "No EKS cluster '${cluster_name}' found in ${AWS_REGION:-us-east-1}."
    return 1
  fi

  aws eks update-kubeconfig \
    --region "${AWS_REGION:-us-east-1}" \
    --name "${cluster_name}" >/dev/null
  echo "${cluster_name}"
}

# Remove evicted/failed router pods before rollout (avoids repeated image pulls on disk-pressure nodes).
cleanup_router_pods() {
  echo "Cleaning up failed/evicted router pods..."
  kubectl delete pods -n vllm -l app=vllm-router --field-selector=status.phase=Failed --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete pods -n vllm -l app=vllm-router --field-selector=status.phase=Unknown --ignore-not-found --wait=false 2>/dev/null || true
}
