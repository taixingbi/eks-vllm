#!/usr/bin/env bash
# Tear down Kubernetes workloads, Helm add-ons, and Terraform infrastructure.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm.sh"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required"
  exit 1
fi

confirm_action "destroy all infrastructure"

AWS_REGION="${AWS_REGION:-us-east-1}"
cd "$TF_DIR"

if CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null); then
  if aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    AUTO_APPROVE=1 "${ROOT}/scripts/delete-k8s.sh"
    AUTO_APPROVE=1 "${ROOT}/scripts/delete-addons.sh"
  else
    echo "Could not configure kubectl; skipping Kubernetes cleanup."
  fi
else
  echo "Cluster not found in Terraform state; skipping Kubernetes cleanup."
fi

terraform init -input=false
terraform destroy -auto-approve

echo "Infrastructure destroyed (${TF_ENVIRONMENT})."
