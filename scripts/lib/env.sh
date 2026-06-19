#!/usr/bin/env bash
# Resolve Terraform environment directory from TF_ENVIRONMENT.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_ENVIRONMENT="${TF_ENVIRONMENT:-prod}"

case "${TF_ENVIRONMENT}" in
  dev|prod) ;;
  *)
    echo "Unsupported TF_ENVIRONMENT: ${TF_ENVIRONMENT} (expected dev or prod)"
    exit 1
    ;;
esac

export ROOT
export TF_ENVIRONMENT
export TF_DIR="${ROOT}/terraform/environments/${TF_ENVIRONMENT}"
export OUT_DIR="${OUT_DIR:-${ROOT}/kubernetes/.generated/${TF_ENVIRONMENT}}"

case "${TF_ENVIRONMENT}" in
  prod) export HF_SECRET_NAME="${HF_SECRET_NAME:-qwen-vllm/hf-token}" ;;
  dev)  export HF_SECRET_NAME="${HF_SECRET_NAME:-qwen-vllm-dev/hf-token}" ;;
esac
