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

helm_uninstall() {
  local release=$1
  local namespace=$2
  if ! helm list -n "${namespace}" -q 2>/dev/null | grep -Fxq "${release}"; then
    echo "Helm release ${release} not installed in ${namespace}, skipping"
    return 0
  fi
  if ! helm uninstall "${release}" -n "${namespace}"; then
    echo "Warning: failed to uninstall ${release} from ${namespace}, continuing"
  fi
}

helm_uninstall kube-prometheus-stack monitoring
helm_uninstall keda keda
helm_uninstall external-secrets external-secrets
helm_uninstall aws-efs-csi-driver kube-system
helm_uninstall karpenter kube-system
helm_uninstall aws-load-balancer-controller kube-system

kubectl_delete_ns() {
  kubectl delete namespace "$1" --ignore-not-found --wait=false 2>/dev/null || {
    echo "Warning: could not delete namespace $1 (cluster may be unreachable); continuing"
  }
}

kubectl_delete_ns monitoring
kubectl_delete_ns keda
kubectl_delete_ns external-secrets

echo "Helm add-ons uninstalled (${TF_ENVIRONMENT})."
