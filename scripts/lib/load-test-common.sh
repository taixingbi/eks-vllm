#!/usr/bin/env bash
# Shared helpers for load-test-slo.sh and load-test-autoscale.sh.
set -euo pipefail

LOAD_TEST_HTTP_HEADERS=()

load_test_source_env() {
  # shellcheck source=scripts/lib/env.sh
  source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
}

# Resolve INFERENCE_URL and LOAD_TEST_HTTP_HEADERS if not preset.
# Header entries are "Name: value" for load_test_runner.py --header.
load_test_resolve_endpoint() {
  LOAD_TEST_HTTP_HEADERS=()

  if [[ -n "${INFERENCE_URL:-}" ]]; then
    if [[ -n "${PLATFORM_GATEWAY_API_KEY:-}" ]]; then
      LOAD_TEST_HTTP_HEADERS=("X-API-Key: ${PLATFORM_GATEWAY_API_KEY}")
    elif [[ -n "${API_KEY:-}" ]]; then
      LOAD_TEST_HTTP_HEADERS=("X-API-Key: ${API_KEY}")
    fi
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    INFERENCE_URL="http://127.0.0.1:8000/v1"
    return 0
  fi

  # Prefer ALB when ingress exists.
  local alb=""
  alb=$(kubectl get ingress -n vllm -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${alb}" && "${alb}" != "null" ]]; then
    INFERENCE_URL="http://${alb}/v1"
    local key="${PLATFORM_GATEWAY_API_KEY:-${API_KEY:-dev-change-me}}"
    LOAD_TEST_HTTP_HEADERS=("X-API-Key: ${key}")
    return 0
  fi

  INFERENCE_URL="http://127.0.0.1:8000/v1"
  echo "Note: no ingress found — use port-forward or set INFERENCE_URL"
}

prom_query() {
  local prom_url="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
  local query=$1
  curl -sf -G "${prom_url}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("data",{}).get("result",[]); print(r[0]["value"][1] if r else "nan")' 2>/dev/null \
    || echo "nan"
}

load_test_k8s_snapshot() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local ready desired hpa gpu pending
  ready=$(kubectl get deploy vllm-qwen -n vllm -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  desired=$(kubectl get deploy vllm-qwen -n vllm -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  hpa=$(kubectl get hpa -n vllm -o jsonpath='{range .items[*]}{.metadata.name}={.status.currentReplicas}/{.spec.maxReplicas}{" "}{end}' 2>/dev/null || echo "none")
  gpu=$(kubectl get nodes -l workload=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pending=$(kubectl get pods -n vllm -l app=vllm-qwen --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "${ts} ready=${ready}/${desired} hpa=${hpa} gpu_nodes=${gpu} pending_pods=${pending}"
}
