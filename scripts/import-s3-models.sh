#!/usr/bin/env bash
# Re-import an existing model-artifacts bucket after destroy preserved S3 state.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is required"
  exit 1
fi

terraform_init_if_needed

in_state() {
  terraform -chdir="${TF_DIR}" state show "$1" >/dev/null 2>&1
}

tf_import() {
  local addr="$1"
  local id="$2"
  if in_state "$addr"; then
    echo "  skip (already in state): $addr"
    return 0
  fi
  echo "  import: $addr <= $id"
  terraform -chdir="${TF_DIR}" import "$addr" "$id"
}

BUCKET="${1:-}"
if [[ -z "${BUCKET}" ]]; then
  BUCKET=$(terraform -chdir="${TF_DIR}" output -raw model_artifacts_bucket_name 2>/dev/null || true)
fi
if [[ -z "${BUCKET}" ]]; then
  case "${TF_ENVIRONMENT}" in
    dev) BUCKET="qwen-vllm-dev-model-artifacts" ;;
    prod) BUCKET="qwen-vllm-model-artifacts" ;;
    *) echo "Unknown TF_ENVIRONMENT; pass bucket name as first argument"; exit 1 ;;
  esac
fi

if ! aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "S3 bucket ${BUCKET} not found in AWS; nothing to import."
  exit 0
fi

echo "Importing existing S3 model bucket: ${BUCKET}"
tf_import 'module.s3_models.aws_s3_bucket.model_artifacts' "${BUCKET}"
tf_import 'module.s3_models.aws_s3_bucket_versioning.model_artifacts' "${BUCKET}"
tf_import 'module.s3_models.aws_s3_bucket_server_side_encryption_configuration.model_artifacts' "${BUCKET}"
tf_import 'module.s3_models.aws_s3_bucket_public_access_block.model_artifacts' "${BUCKET}"
tf_import 'module.s3_models.aws_s3_bucket_policy.model_artifacts' "${BUCKET}"

echo "Import complete. Run 'terraform plan' to reconcile IAM/IRSA resources."
