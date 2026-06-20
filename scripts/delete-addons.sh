#!/usr/bin/env bash
# Uninstall Helm add-ons installed by install-addons.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required"
  exit 1
fi

confirm_action "uninstall Helm add-ons"

if ! CLUSTER_NAME=$(configure_kubectl); then
  echo "No cluster to clean up for ${TF_ENVIRONMENT}."
  exit 0
fi

echo "Uninstalling Helm add-ons from ${CLUSTER_NAME}..."

helm uninstall kube-prometheus-stack -n monitoring --ignore-not-found
helm uninstall keda -n keda --ignore-not-found
helm uninstall external-secrets -n external-secrets --ignore-not-found
helm uninstall aws-efs-csi-driver -n kube-system --ignore-not-found
helm uninstall karpenter -n kube-system --ignore-not-found
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found

kubectl delete namespace monitoring --ignore-not-found --wait=false
kubectl delete namespace keda --ignore-not-found --wait=false
kubectl delete namespace external-secrets --ignore-not-found --wait=false

echo "Helm add-ons uninstalled (${TF_ENVIRONMENT})."
