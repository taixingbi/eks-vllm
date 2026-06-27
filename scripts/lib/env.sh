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
    if [[ -z "${INSTANCE_TYPE:-}" ]]; then export INSTANCE_TYPE=g5.4xlarge; else export INSTANCE_TYPE; fi
    if [[ -z "${MODEL_NAME:-}" ]]; then export MODEL_NAME=Qwen/Qwen3-8B; else export MODEL_NAME; fi
    ;;
  dev)
    export HF_SECRET_NAME="${HF_SECRET_NAME:-qwen-vllm-dev/hf-token}"
    if [[ -z "${INSTANCE_TYPE:-}" ]]; then export INSTANCE_TYPE=g5.2xlarge; else export INSTANCE_TYPE; fi
    if [[ -z "${MODEL_NAME:-}" ]]; then export MODEL_NAME=Qwen/Qwen2.5-7B-Instruct; else export MODEL_NAME; fi
    ;;
esac
export MODEL_BASENAME="${MODEL_NAME##*/}"
export MODEL_VERSION="${MODEL_VERSION:-v1}"
export MODEL_PATH="/models/${MODEL_BASENAME}/${MODEL_VERSION}"
export MODEL_S3_PREFIX="models/${MODEL_BASENAME}/${MODEL_VERSION}"
export INSTANCE_FAMILY="${INSTANCE_TYPE%%.*}"
export INSTANCE_SIZE="${INSTANCE_TYPE#*.}"

# Prod always installs Prometheus; dev enables Step 6 with DEV_ENABLE_PROMETHEUS=1.
# KEDA (Step 7) requires Prometheus — enabling KEDA on dev also enables Prometheus.
if [[ "${TF_ENVIRONMENT}" == "prod" ]] \
  || [[ "${DEV_ENABLE_PROMETHEUS:-}" == "1" ]] \
  || [[ "${DEV_ENABLE_KEDA:-}" == "1" ]]; then
  export ENABLE_PROMETHEUS=1
else
  export ENABLE_PROMETHEUS=0
fi

# Prod always installs KEDA; dev enables Step 7 with DEV_ENABLE_KEDA=1.
if [[ "${TF_ENVIRONMENT}" == "prod" ]] || [[ "${DEV_ENABLE_KEDA:-}" == "1" ]]; then
  export ENABLE_KEDA=1
else
  export ENABLE_KEDA=0
fi

# Prod always installs ALB; dev enables Step 8 with DEV_ENABLE_ALB=1.
if [[ "${TF_ENVIRONMENT}" == "prod" ]] || [[ "${DEV_ENABLE_ALB:-}" == "1" ]]; then
  export ENABLE_ALB=1
else
  export ENABLE_ALB=0
fi

# Dev HTTP-only ALB (port 80, no ACM / custom hostname). Ignored on prod.
if [[ "${TF_ENVIRONMENT}" == "dev" ]] && [[ "${DEV_ALB_HTTP_ONLY:-}" == "1" ]]; then
  export ALB_HTTP_ONLY=1
else
  export ALB_HTTP_ONLY=0
fi

# Prod full stack includes Grafana; dev enables with DEV_ENABLE_GRAFANA=1 (requires Prometheus).
if [[ "${TF_ENVIRONMENT}" == "prod" ]] || [[ "${DEV_ENABLE_GRAFANA:-}" == "1" ]]; then
  export ENABLE_GRAFANA=1
else
  export ENABLE_GRAFANA=0
fi

# Gateway router (phases 1–8): prod always; dev enables with DEV_ENABLE_ROUTER=1.
if [[ "${TF_ENVIRONMENT}" == "prod" ]] || [[ "${DEV_ENABLE_ROUTER:-}" == "1" ]]; then
  export ENABLE_ROUTER=1
else
  export ENABLE_ROUTER=0
fi

# LMCache shared KV (phase 9): prod default when router on; dev opt-in DEV_ENABLE_LMCACHE=1.
if [[ "${ENABLE_ROUTER}" == "1" ]] && { [[ "${TF_ENVIRONMENT}" == "prod" ]] || [[ "${DEV_ENABLE_LMCACHE:-}" == "1" ]]; }; then
  export ENABLE_LMCACHE=1
else
  export ENABLE_LMCACHE=0
fi

# Routing logic: session (phase 1), prefixaware (phase 8), kvaware (phase 8/9 with LMCache).
# Override with ROUTER_ROUTING_LOGIC env var.
if [[ -n "${ROUTER_ROUTING_LOGIC:-}" ]]; then
  export ROUTER_ROUTING_LOGIC
elif [[ "${ENABLE_LMCACHE}" == "1" ]]; then
  export ROUTER_ROUTING_LOGIC=kvaware
elif [[ "${TF_ENVIRONMENT}" == "prod" ]] && [[ "${ENABLE_ROUTER}" == "1" ]]; then
  export ROUTER_ROUTING_LOGIC=prefixaware
else
  export ROUTER_ROUTING_LOGIC=session
fi

export ROUTER_SESSION_KEY="${ROUTER_SESSION_KEY:-X-Session-Id}"

# shellcheck source=scripts/lib/chart-versions.sh
source "$(dirname "${BASH_SOURCE[0]}")/chart-versions.sh"
