#!/usr/bin/env bash
# Download model from Hugging Face and upload to S3 with a versioned manifest.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required"
  exit 1
fi
if ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "huggingface-cli is required (pip install huggingface_hub[cli])"
  exit 1
fi

cd "$TF_DIR"
BUCKET=$(terraform output -raw model_artifacts_bucket_name)
S3_URI="s3://${BUCKET}/${MODEL_S3_PREFIX}"
LOCAL_DIR="${LOCAL_DIR:-/tmp/${MODEL_BASENAME}-${MODEL_VERSION}}"

echo "Model:      ${MODEL_NAME}"
echo "Version:    ${MODEL_VERSION}"
echo "Local dir:  ${LOCAL_DIR}"
echo "S3 URI:     ${S3_URI}/"

s3_model_exists() {
  aws s3api head-object \
    --bucket "${BUCKET}" \
    --key "${MODEL_S3_PREFIX}/.model-manifest.json" \
    >/dev/null 2>&1 \
  && aws s3api head-object \
    --bucket "${BUCKET}" \
    --key "${MODEL_S3_PREFIX}/config.json" \
    >/dev/null 2>&1
}

if s3_model_exists && [[ "${FORCE_UPLOAD:-}" != "1" ]]; then
  echo "Model already exists in S3 at ${S3_URI}/ — skipping HuggingFace download and upload."
  echo "Set FORCE_UPLOAD=1 to overwrite this version."
  aws s3 cp "${S3_URI}/.model-manifest.json" - 2>/dev/null || true
  exit 0
fi

if [[ ! -f "${LOCAL_DIR}/config.json" ]]; then
  echo "Model not in S3 (or FORCE_UPLOAD=1); downloading ${MODEL_NAME} from HuggingFace..."
  mkdir -p "${LOCAL_DIR}"
  HF_TOKEN="${HF_TOKEN:-}" huggingface-cli download "${MODEL_NAME}" \
    --local-dir "${LOCAL_DIR}" \
    --local-dir-use-symlinks False
fi

echo "Writing manifest..."
python3 - "${MODEL_NAME}" "${MODEL_VERSION}" "${LOCAL_DIR}" <<'PY'
import json, sys
from pathlib import Path

model_id, version, root = sys.argv[1], sys.argv[2], Path(sys.argv[3])
files = [f for f in root.rglob("*") if f.is_file() and f.name != ".model-manifest.json"]
manifest = {
    "model_id": model_id,
    "version": version,
    "file_count": len(files),
    "total_bytes": sum(f.stat().st_size for f in files),
}
(root / ".model-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
PY

echo "Uploading to ${S3_URI}/ ..."
aws s3 sync "${LOCAL_DIR}/" "${S3_URI}/" --no-progress

echo "Verifying S3 manifest..."
aws s3 cp "${S3_URI}/.model-manifest.json" - >/dev/null
aws s3 ls "${S3_URI}/config.json" >/dev/null

echo "Upload complete: ${S3_URI}/"
echo "Deploy with MODEL_VERSION=${MODEL_VERSION} make deploy-k8s TF_ENVIRONMENT=${TF_ENVIRONMENT}"
