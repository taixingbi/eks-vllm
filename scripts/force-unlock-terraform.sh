#!/usr/bin/env bash
# Force-unlock Terraform remote state (use when CI/local apply crashed and left a stale lock).
# Usage:
#   LOCK_ID=7fa01ed7-69a4-1676-b294-c1346307bda2 TF_ENVIRONMENT=dev ./scripts/force-unlock-terraform.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

if [[ -z "${LOCK_ID:-}" ]]; then
  echo "LOCK_ID is required (from terraform lock error output)."
  echo "Example: LOCK_ID=7fa01ed7-... TF_ENVIRONMENT=dev $0"
  exit 1
fi

cd "$TF_DIR"
terraform init -input=false
terraform force-unlock -force "${LOCK_ID}"
echo "Lock ${LOCK_ID} released for ${TF_ENVIRONMENT}."
