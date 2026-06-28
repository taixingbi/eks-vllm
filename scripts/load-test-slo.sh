#!/usr/bin/env bash
# SLO load test with streaming TTFT + client-side p95 latencies.
#
# Usage:
#   make load-test-slo TF_ENVIRONMENT=dev
#   INFERENCE_URL=http://<alb>/v1 PLATFORM_GATEWAY_API_KEY=... make load-test-slo TF_ENVIRONMENT=dev
#   kubectl port-forward -n vllm svc/vllm-router 8000:8000 &
#   INFERENCE_URL=http://127.0.0.1:8000/v1 make load-test-slo TF_ENVIRONMENT=dev
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/load-test-common.sh
source "${ROOT}/scripts/lib/load-test-common.sh"

load_test_source_env

REQUESTS="${REQUESTS:-40}"
CONCURRENCY="${CONCURRENCY:-8}"
STREAM="${STREAM:-1}"
MAX_TOKENS="${MAX_TOKENS:-32}"
MAX_TTFT_MS="${MAX_TTFT_MS:-2000}"
MAX_E2E_MS="${MAX_E2E_MS:-10000}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"

if [[ -z "${MODEL_PATH:-}" ]]; then
  echo "MODEL_PATH is required (set via env.sh / MODEL_NAME)"
  exit 1
fi

load_test_resolve_endpoint

CHAT_URL="${INFERENCE_URL%/}/chat/completions"
RUNNER_ARGS=(
  --url "${CHAT_URL}"
  --model "${MODEL_PATH}"
  --requests "${REQUESTS}"
  --concurrency "${CONCURRENCY}"
  --max-tokens "${MAX_TOKENS}"
)
if [[ "${STREAM}" == "1" ]]; then
  RUNNER_ARGS+=(--stream)
else
  RUNNER_ARGS+=(--no-stream)
fi
if ((${#LOAD_TEST_HTTP_HEADERS[@]} > 0)); then
  for h in "${LOAD_TEST_HTTP_HEADERS[@]}"; do
    RUNNER_ARGS+=(--header "${h}")
  done
fi

echo "Load test (SLO): requests=${REQUESTS} concurrency=${CONCURRENCY} stream=${STREAM}"
echo "Endpoint: ${CHAT_URL}"
echo "Model: ${MODEL_PATH}"
echo "Targets: TTFT p95 < ${MAX_TTFT_MS}ms, e2e p95 < ${MAX_E2E_MS}ms, error rate < ${MAX_ERROR_RATE}"

STATS_FILE=$(mktemp)
python3 "${ROOT}/scripts/lib/load_test_runner.py" "${RUNNER_ARGS[@]}" > "${STATS_FILE}"
cat "${STATS_FILE}"

IFS=$'\t' read -r TTFT_P95 E2E_P95 ERROR_RATE SUCCESS FAIL <<< "$(python3 - <<PY
import json
with open("${STATS_FILE}") as f:
    s = json.load(f)
ttft = s.get("ttft_p95_ms")
e2e = s.get("e2e_p95_ms")
print(
    int(ttft if ttft is not None else 999999),
    int(e2e if e2e is not None else 999999),
    s.get("error_rate", 1.0),
    s.get("success", 0),
    s.get("fail", 0),
    sep="\t",
)
PY
)"
rm -f "${STATS_FILE}"

echo ""
echo "Results: success=${SUCCESS} fail=${FAIL} error_rate=${ERROR_RATE}"
echo "Client TTFT p95: ${TTFT_P95}ms | e2e p95: ${E2E_P95}ms"

failed=0
if python3 -c "import sys; sys.exit(0 if float('${ERROR_RATE}') < float('${MAX_ERROR_RATE}') else 1)"; then
  echo "PASS error rate"
else
  echo "FAIL error rate >= ${MAX_ERROR_RATE}"
  failed=1
fi
if [[ "${TTFT_P95}" -lt "${MAX_TTFT_MS}" ]]; then
  echo "PASS TTFT p95"
else
  echo "FAIL TTFT p95 >= ${MAX_TTFT_MS}ms"
  failed=1
fi
if [[ "${E2E_P95}" -lt "${MAX_E2E_MS}" ]]; then
  echo "PASS e2e p95"
else
  echo "FAIL e2e p95 >= ${MAX_E2E_MS}ms"
  failed=1
fi

if command -v kubectl >/dev/null 2>&1 && curl -sf "${PROMETHEUS_URL:-http://127.0.0.1:9090}/-/ready" >/dev/null 2>&1; then
  echo ""
  echo "Prometheus (server-side, 5m rate):"
  echo "  vllm:ttft:p95=$(prom_query 'vllm:ttft:p95')"
  echo "  vllm:e2e_latency:p95=$(prom_query 'vllm:e2e_latency:p95')"
  echo "  vllm:generation_tps:sum=$(prom_query 'vllm:generation_tps:sum')"
  echo "  vllm:queue_depth:sum=$(prom_query 'vllm:queue_depth:sum')"
else
  echo ""
  echo "Tip: port-forward Prometheus for server-side SLO metrics:"
  echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
fi

echo ""
echo "For KEDA scale-up evidence run: make load-test-autoscale TF_ENVIRONMENT=${TF_ENVIRONMENT}"
exit "${failed}"
