#!/bin/sh
# Sync model weights from S3 to a local directory (EFS mount). Validates manifest.
set -eu

: "${MODEL_S3_URI:?MODEL_S3_URI is required}"
: "${MODEL_PATH:?MODEL_PATH is required}"

MANIFEST_NAME=".model-manifest.json"
LOCAL_MANIFEST="${MODEL_PATH}/${MANIFEST_NAME}"
TMP_MANIFEST="$(mktemp)"

cleanup() {
  rm -f "${TMP_MANIFEST}"
}
trap cleanup EXIT

needs_sync() {
  if [ ! -f "${LOCAL_MANIFEST}" ] || [ ! -f "${MODEL_PATH}/config.json" ]; then
    return 0
  fi
  if ! aws s3 cp "${MODEL_S3_URI}/${MANIFEST_NAME}" "${TMP_MANIFEST}" --quiet 2>/dev/null; then
    echo "S3 manifest missing at ${MODEL_S3_URI}/${MANIFEST_NAME}"
    return 0
  fi
  LOCAL_VER=$(python3 -c "import json; print(json.load(open('${LOCAL_MANIFEST}'))['version'])" 2>/dev/null || echo "")
  REMOTE_VER=$(python3 -c "import json; print(json.load(open('${TMP_MANIFEST}'))['version'])" 2>/dev/null || echo "")
  if [ "${LOCAL_VER}" = "${REMOTE_VER}" ] && [ -n "${LOCAL_VER}" ]; then
    echo "Model ${LOCAL_VER} already cached at ${MODEL_PATH}, skipping S3 sync."
    return 1
  fi
  echo "Model version changed (${LOCAL_VER:-none} -> ${REMOTE_VER}), re-syncing..."
  return 0
}

validate_manifest() {
  python3 - "${MODEL_PATH}" <<'PY'
import json, sys
from pathlib import Path

model_path = Path(sys.argv[1])
manifest_path = model_path / ".model-manifest.json"
manifest = json.loads(manifest_path.read_text())
files = [f for f in model_path.rglob("*") if f.is_file() and f.name != ".model-manifest.json"]
actual_count = len(files)
actual_bytes = sum(f.stat().st_size for f in files)
if actual_count != manifest["file_count"]:
    raise SystemExit(f"file_count mismatch: expected {manifest['file_count']}, got {actual_count}")
if actual_bytes != manifest["total_bytes"]:
    raise SystemExit(f"total_bytes mismatch: expected {manifest['total_bytes']}, got {actual_bytes}")
if not (model_path / "config.json").is_file():
    raise SystemExit("config.json missing after sync")
print(f"Validated {manifest['model_id']} {manifest['version']}: {actual_count} files, {actual_bytes} bytes")
PY
}

if ! needs_sync; then
  validate_manifest
  exit 0
fi

mkdir -p "${MODEL_PATH}"
echo "Syncing ${MODEL_S3_URI}/ -> ${MODEL_PATH}/ ..."
aws s3 sync "${MODEL_S3_URI}/" "${MODEL_PATH}/" --no-progress
validate_manifest
echo "Model sync complete."
