#!/usr/bin/env bash
# P0/P1 Terraform policy checks: fmt, validate, tflint, checkov.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TF_VERSION="${TF_VERSION:-1.15.6}"
SKIP_TFLINT="${SKIP_TFLINT:-0}"
SKIP_CHECKOV="${SKIP_CHECKOV:-0}"

terraform_roots=(
  terraform/bootstrap
  terraform/modules/alb-controller
  terraform/modules/ecr
  terraform/modules/efs
  terraform/modules/eks
  terraform/modules/external-secrets
  terraform/modules/karpenter
  terraform/modules/vpc
  terraform/environments/dev
  terraform/environments/prod
)

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive terraform/

echo "==> terraform init -backend=false && validate (all roots)"
for dir in "${terraform_roots[@]}"; do
  echo "    ${dir}"
  terraform -chdir="${dir}" init -backend=false -input=false -upgrade=false
  terraform -chdir="${dir}" validate -no-color
done

if [[ "${SKIP_TFLINT}" != "1" ]]; then
  if command -v tflint >/dev/null 2>&1; then
    echo "==> tflint --recursive"
    (cd terraform && tflint --init && tflint --recursive -f compact)
  else
    echo "WARN: tflint not installed; set SKIP_TFLINT=1 or install tflint"
    exit 1
  fi
fi

if [[ "${SKIP_CHECKOV}" != "1" ]]; then
  if command -v checkov >/dev/null 2>&1; then
    echo "==> checkov (terraform/environments)"
    checkov -d terraform/environments --config-file "${ROOT}/.checkov.yml"
  else
    echo "WARN: checkov not installed; set SKIP_CHECKOV=1 or pip install checkov"
    exit 1
  fi
fi

echo "Terraform policy checks passed."
