#!/usr/bin/env bash
# Keep model-artifacts S3 bucket (and weights) when destroying Terraform stack.
set -euo pipefail

preserve_s3_models_in_state() {
  local tf_dir="${1:?TF_DIR required}"

  if ! command -v terraform >/dev/null 2>&1; then
    return 0
  fi

  if ! terraform -chdir="${tf_dir}" state list 2>/dev/null | grep -q '^module\.s3_models'; then
    echo "No module.s3_models in state; nothing to preserve."
    return 0
  fi

  echo "Preserving model-artifacts S3 bucket (detaching module.s3_models from Terraform state)..."
  if ! terraform -chdir="${tf_dir}" state rm -lock=false 'module.s3_models'; then
    echo "Warning: failed to remove module.s3_models from state; destroy may fail on S3 bucket."
    return 1
  fi
  echo "S3 model weights will remain in AWS; re-run 'make import-s3-models' before the next apply."
}
