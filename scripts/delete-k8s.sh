#!/usr/bin/env bash
# Remove Kubernetes workloads from the selected environment.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/kubectl-delete.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required"
  exit 1
fi

confirm_action "delete Kubernetes workloads"

if ! CLUSTER_NAME=$(configure_kubectl); then
  echo "Nothing to delete for ${TF_ENVIRONMENT}."
  exit 0
fi

echo "Deleting Kubernetes workloads from ${CLUSTER_NAME}..."

echo "Deleting vLLM resources..."
kubectl_delete_crd_kind scaledobjects.keda.sh scaledobject --all -n vllm
kubectl_delete ingress --all -n vllm
kubectl_delete deployment --all -n vllm
kubectl_delete service --all -n vllm
kubectl_delete job --all -n vllm
kubectl_delete_crd_kind externalsecrets.external-secrets.io externalsecret --all -n vllm
kubectl_delete pvc --all -n vllm
kubectl_delete configmap --all -n vllm

if [[ -d "${OUT_DIR}/monitoring" ]]; then
  echo "Deleting monitoring resources..."
  kubectl_delete -f "${OUT_DIR}/monitoring/"
fi

echo "Deleting Karpenter GPU pools..."
kubectl_delete_crd_kind nodepools.karpenter.sh nodepool g5-ondemand g5-spot
kubectl_delete_crd_kind ec2nodeclasses.karpenter.k8s.aws ec2nodeclass g5-gpu

if [[ -f "${OUT_DIR}/nvidia-device-plugin.yaml" ]]; then
  kubectl_delete -f "${OUT_DIR}/nvidia-device-plugin.yaml"
else
  kubectl_delete -f "${ROOT}/kubernetes/gpu/nvidia-device-plugin.yaml"
fi

echo "Waiting for GPU nodes to terminate..."
for _ in $(seq 1 30); do
  count=$(kubectl get nodes -l workload=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${count}" == "0" ]]; then
    break
  fi
  sleep 20
done

kubectl_delete namespace vllm
kubectl_delete_crd_kind clustersecretstores.external-secrets.io clustersecretstore aws-secrets-manager

echo "Kubernetes workloads deleted (${TF_ENVIRONMENT})."
