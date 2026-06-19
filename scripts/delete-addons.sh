#!/usr/bin/env bash
# Uninstall Helm add-ons installed by install-addons.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required"
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

confirm_action "uninstall Helm add-ons"

helm uninstall kube-prometheus-stack -n monitoring --ignore-not-found
helm uninstall keda -n keda --ignore-not-found
helm uninstall external-secrets -n external-secrets --ignore-not-found
helm uninstall aws-efs-csi-driver -n kube-system --ignore-not-found

kubectl delete namespace monitoring --ignore-not-found --wait=false
kubectl delete namespace keda --ignore-not-found --wait=false
kubectl delete namespace external-secrets --ignore-not-found --wait=false

echo "Helm add-ons uninstalled (${TF_ENVIRONMENT})."
