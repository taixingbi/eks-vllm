#!/usr/bin/env bash
# Build and push the vLLM image to ECR.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
VLLM_IMAGE_TAG="${VLLM_IMAGE_TAG:-v0.8.4}"

cd "$TF_DIR"
ECR_URL=$(terraform output -raw ecr_repository_url)
ECR_REGISTRY="${ECR_URL%%/*}"

aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker build -t "${ECR_URL}:${VLLM_IMAGE_TAG}" -f "${ROOT}/docker/Dockerfile.vllm" "${ROOT}"

MODEL_DOWNLOADER_TAG="${MODEL_DOWNLOADER_TAG:-model-downloader}"
docker build -t "${ECR_URL}:${MODEL_DOWNLOADER_TAG}" -f "${ROOT}/docker/Dockerfile.model-downloader" "${ROOT}"

if [[ -n "${GITHUB_SHA:-}" ]]; then
  docker tag "${ECR_URL}:${VLLM_IMAGE_TAG}" "${ECR_URL}:${GITHUB_SHA:0:7}"
  docker push "${ECR_URL}:${GITHUB_SHA:0:7}"
fi

docker push "${ECR_URL}:${VLLM_IMAGE_TAG}"
docker push "${ECR_URL}:${MODEL_DOWNLOADER_TAG}"
echo "Pushed ${ECR_URL}:${VLLM_IMAGE_TAG} (${TF_ENVIRONMENT})"
echo "Pushed ${ECR_URL}:${MODEL_DOWNLOADER_TAG} (${TF_ENVIRONMENT})"
