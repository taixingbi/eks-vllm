#!/usr/bin/env bash
# Tear down Kubernetes workloads, Helm add-ons, and Terraform infrastructure.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm.sh"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required"
  exit 1
fi

confirm_action "destroy all infrastructure"

AWS_REGION="${AWS_REGION:-us-east-1}"

if CLUSTER_NAME=$(configure_kubectl 2>/dev/null); then
  AUTO_APPROVE=1 "${ROOT}/scripts/delete-k8s.sh"
  AUTO_APPROVE=1 "${ROOT}/scripts/delete-addons.sh"
else
  echo "No running cluster for ${TF_ENVIRONMENT}; skipping Kubernetes cleanup."
fi

terraform_init_if_needed
terraform -chdir="${TF_DIR}" init -input=false

if ! terraform -chdir="${TF_DIR}" destroy -auto-approve; then
  if ! cluster_exists "$(resolve_cluster_name)" && [[ ! -f "${TF_DIR}/.terraform/terraform.tfstate" ]]; then
    echo "Nothing to destroy for ${TF_ENVIRONMENT}."
    exit 0
  fi
  exit 1
fi

echo "Infrastructure destroyed (${TF_ENVIRONMENT})."
