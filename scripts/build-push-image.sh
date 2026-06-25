#!/usr/bin/env bash
# Build and push the vLLM image to ECR.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
VLLM_IMAGE_TAG="${VLLM_IMAGE_TAG:-v0.8.4}"
MODEL_DOWNLOADER_TAG="${MODEL_DOWNLOADER_TAG:-model-downloader}"
# Skip rebuilding pinned vLLM tag when already in ECR (saves CI disk/time). Set FORCE_ECR_BUILD=1 to override.
SKIP_ECR_BUILD_IF_EXISTS="${SKIP_ECR_BUILD_IF_EXISTS:-1}"

docker_build_push() {
  local tag=$1
  local dockerfile=$2
  local context=$3

  if docker buildx version >/dev/null 2>&1; then
    docker buildx build \
      --platform linux/amd64 \
      --provenance=false \
      --sbom=false \
      -t "${ECR_URL}:${tag}" \
      -f "${dockerfile}" \
      --push \
      "${context}"
  else
    docker build -t "${ECR_URL}:${tag}" -f "${dockerfile}" "${context}"
    docker push "${ECR_URL}:${tag}"
  fi
}

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  "${ROOT}/scripts/ci-free-disk.sh"
fi

cd "$TF_DIR"
ECR_URL=$(terraform output -raw ecr_repository_url)
ECR_REGISTRY="${ECR_URL%%/*}"
ECR_REPO_NAME="${ECR_URL##*/}"

aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

ecr_image_exists() {
  local tag=$1
  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO_NAME}" \
    --image-ids "imageTag=${tag}" >/dev/null 2>&1
}

if [[ "${SKIP_ECR_BUILD_IF_EXISTS}" == "1" ]] \
  && [[ "${FORCE_ECR_BUILD:-}" != "1" ]] \
  && ecr_image_exists "${VLLM_IMAGE_TAG}"; then
  echo "Skipping vLLM build; ${ECR_REPO_NAME}:${VLLM_IMAGE_TAG} already exists in ECR."
else
  echo "Building and pushing ${ECR_URL}:${VLLM_IMAGE_TAG} ..."
  docker_build_push "${VLLM_IMAGE_TAG}" "${ROOT}/docker/Dockerfile.vllm" "${ROOT}"
fi

if [[ "${SKIP_ECR_BUILD_IF_EXISTS}" == "1" ]] \
  && [[ "${FORCE_ECR_BUILD:-}" != "1" ]] \
  && ecr_image_exists "${MODEL_DOWNLOADER_TAG}"; then
  echo "Skipping model-downloader build; ${ECR_REPO_NAME}:${MODEL_DOWNLOADER_TAG} already exists in ECR."
else
  echo "Building and pushing ${ECR_URL}:${MODEL_DOWNLOADER_TAG} ..."
  docker_build_push "${MODEL_DOWNLOADER_TAG}" "${ROOT}/docker/Dockerfile.model-downloader" "${ROOT}"
fi

if [[ -n "${GITHUB_SHA:-}" ]]; then
  SHORT_SHA="${GITHUB_SHA:0:7}"
  if ecr_image_exists "${SHORT_SHA}"; then
    echo "Commit tag ${SHORT_SHA} already in ECR, skipping retag."
  else
    # Pull manifest from ECR and push under commit tag (no local rebuild).
    docker buildx imagetools create -t "${ECR_URL}:${SHORT_SHA}" "${ECR_URL}:${VLLM_IMAGE_TAG}" 2>/dev/null \
      || { docker pull "${ECR_URL}:${VLLM_IMAGE_TAG}"; docker tag "${ECR_URL}:${VLLM_IMAGE_TAG}" "${ECR_URL}:${SHORT_SHA}"; docker push "${ECR_URL}:${SHORT_SHA}"; }
  fi
fi

echo "ECR images ready: ${ECR_URL}:${VLLM_IMAGE_TAG}, ${ECR_URL}:${MODEL_DOWNLOADER_TAG} (${TF_ENVIRONMENT})"
