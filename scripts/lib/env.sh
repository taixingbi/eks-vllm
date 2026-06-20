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
  prod)
    export HF_SECRET_NAME="${HF_SECRET_NAME:-qwen-vllm/hf-token}"
    export INSTANCE_TYPE="${INSTANCE_TYPE:-g5.4xlarge}"
    ;;
  dev)
    export HF_SECRET_NAME="${HF_SECRET_NAME:-qwen-vllm-dev/hf-token}"
    # Default to g5.2xlarge (8 vCPU) for typical new-account G/VT quota of 8
    export INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
    ;;
esac
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-8B}"
export MODEL_BASENAME="${MODEL_NAME##*/}"
export MODEL_PATH="/models/${MODEL_BASENAME}"
export INSTANCE_FAMILY="${INSTANCE_TYPE%%.*}"
export INSTANCE_SIZE="${INSTANCE_TYPE#*.}"
