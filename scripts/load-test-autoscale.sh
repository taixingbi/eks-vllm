#!/usr/bin/env bash
# Sustained load + KEDA/Karpenter autoscale evidence report.
#
# Produces a markdown report with:
#   - client TTFT/e2e p50/p95, throughput proxy (requests completed)
#   - replica / HPA / GPU node timeline during load
#   - Prometheus queue depth, TTFT, generation tps (if reachable)
#   - scale-up detection and approximate cold-start (new pod -> Ready)
#
# Usage:
#   DEV_ENABLE_KEDA=1 make load-test-autoscale TF_ENVIRONMENT=dev
#   INFERENCE_URL=http://<alb>/v1 PLATFORM_GATEWAY_API_KEY=... make load-test-autoscale TF_ENVIRONMENT=dev
#
# Optional:
#   DURATION_SEC=240 CONCURRENCY=12 LOAD_TEST_REPORT=/tmp/report.md
#   PROMETHEUS_URL=http://127.0.0.1:9090  (or auto port-forward if START_PROM_PF=1)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/load-test-common.sh
source "${ROOT}/scripts/lib/load-test-common.sh"

load_test_source_env

DURATION_SEC="${DURATION_SEC:-180}"
CONCURRENCY="${CONCURRENCY:-10}"
MAX_TOKENS="${MAX_TOKENS:-128}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-15}"
START_PROM_PF="${START_PROM_PF:-1}"
LOAD_TEST_REPORT="${LOAD_TEST_REPORT:-}"

if [[ -z "${MODEL_PATH:-}" ]]; then
  echo "MODEL_PATH is required"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required for autoscale evidence"
  exit 1
fi

load_test_resolve_endpoint
CHAT_URL="${INFERENCE_URL%/}/chat/completions"

PROM_PF_PID=""
LOAD_PID=""
cleanup() {
  [[ -n "${LOAD_PID}" ]] && kill "${LOAD_PID}" 2>/dev/null || true
  [[ -n "${PROM_PF_PID}" ]] && kill "${PROM_PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -z "${PROMETHEUS_URL:-}" ]] && [[ "${START_PROM_PF}" == "1" ]]; then
  if kubectl get svc -n monitoring kube-prometheus-stack-prometheus >/dev/null 2>&1; then
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
    PROM_PF_PID=$!
    PROMETHEUS_URL="http://127.0.0.1:9090"
    for _ in $(seq 1 20); do
      curl -sf "${PROMETHEUS_URL}/-/ready" >/dev/null 2>&1 && break
      sleep 1
    done
  fi
fi

WORKDIR=$(mktemp -d)
TIMELINE="${WORKDIR}/timeline.txt"
BASELINE_REPLICAS=$(kubectl get deploy vllm-qwen -n vllm -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
BASELINE_GPU=$(kubectl get nodes -l workload=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo "=== Load test autoscale (${TF_ENVIRONMENT}) ==="
echo "Duration: ${DURATION_SEC}s  Concurrency: ${CONCURRENCY}  Endpoint: ${CHAT_URL}"
echo "Baseline replicas: ${BASELINE_REPLICAS}  GPU nodes: ${BASELINE_GPU}"
echo ""

load_test_k8s_snapshot | tee "${TIMELINE}"

RUNNER_ARGS=(
  --url "${CHAT_URL}"
  --model "${MODEL_PATH}"
  --duration-sec "${DURATION_SEC}"
  --concurrency "${CONCURRENCY}"
  --max-tokens "${MAX_TOKENS}"
  --stream
  --prompt "Explain GPU autoscaling for large language model inference in 150 words."
)
if ((${#LOAD_TEST_HTTP_HEADERS[@]} > 0)); then
  for h in "${LOAD_TEST_HTTP_HEADERS[@]}"; do
    RUNNER_ARGS+=(--header "${h}")
  done
fi

python3 "${ROOT}/scripts/lib/load_test_runner.py" "${RUNNER_ARGS[@]}" > "${WORKDIR}/client-stats.json" &
LOAD_PID=$!

MAX_REPLICAS="${BASELINE_REPLICAS}"
MAX_GPU="${BASELINE_GPU}"
SCALE_UP_AT=""
NEW_POD=""
NEW_POD_SEEN_EPOCH=""
COLD_START_SEC="n/a"

while kill -0 "${LOAD_PID}" 2>/dev/null; do
  sleep "${POLL_INTERVAL_SEC}"
  line=$(load_test_k8s_snapshot)
  echo "${line}" | tee -a "${TIMELINE}"
  ready=$(echo "${line}" | sed -n 's/.*ready=\([0-9]*\)\/.*/\1/p')
  desired=$(echo "${line}" | sed -n 's/.*ready=[0-9]*\/\([0-9]*\).*/\1/p')
  gpu=$(echo "${line}" | sed -n 's/.*gpu_nodes=\([0-9]*\).*/\1/p')
  if [[ "${ready}" =~ ^[0-9]+$ ]] && [[ "${ready}" -gt "${MAX_REPLICAS}" ]]; then
    MAX_REPLICAS="${ready}"
  fi
  if [[ "${desired}" =~ ^[0-9]+$ ]] && [[ "${desired}" -gt "${MAX_REPLICAS}" ]]; then
    MAX_REPLICAS="${desired}"
  fi
  if [[ "${gpu}" =~ ^[0-9]+$ ]] && [[ "${gpu}" -gt "${MAX_GPU}" ]]; then
    MAX_GPU="${gpu}"
  fi
  if [[ -z "${SCALE_UP_AT}" ]] && [[ "${desired}" =~ ^[0-9]+$ ]] && [[ "${desired}" -gt "${BASELINE_REPLICAS}" ]]; then
    SCALE_UP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  if [[ "${COLD_START_SEC}" == "n/a" ]]; then
    pending_pod=$(kubectl get pods -n vllm -l app=vllm-qwen --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[?(@.status.phase=="Pending")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | tail -1)
    if [[ -n "${pending_pod}" && "${pending_pod}" != "${NEW_POD}" ]]; then
      NEW_POD="${pending_pod}"
      NEW_POD_SEEN_EPOCH=$(date +%s)
    fi
    if [[ -n "${NEW_POD}" ]]; then
      ready_cond=$(kubectl get pod -n vllm "${NEW_POD}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      if [[ "${ready_cond}" == "True" && -n "${NEW_POD_SEEN_EPOCH}" ]]; then
        COLD_START_SEC=$(( $(date +%s) - NEW_POD_SEEN_EPOCH ))
      fi
    fi
  fi
done

wait "${LOAD_PID}" || true
load_test_k8s_snapshot | tee -a "${TIMELINE}"

PROM_BLOCK="Prometheus not reachable — set PROMETHEUS_URL or START_PROM_PF=1 with monitoring installed."
if curl -sf "${PROMETHEUS_URL:-http://127.0.0.1:9090}/-/ready" >/dev/null 2>&1; then
  PROM_BLOCK=$(cat <<EOF
| Metric | Value |
|--------|-------|
| \`vllm:queue_depth:sum\` | $(prom_query 'vllm:queue_depth:sum') |
| \`vllm:ttft:p95\` | $(prom_query 'vllm:ttft:p95') s |
| \`vllm:e2e_latency:p95\` | $(prom_query 'vllm:e2e_latency:p95') s |
| \`vllm:generation_tps:sum\` | $(prom_query 'vllm:generation_tps:sum') tok/s |
| \`max(gpu_cache_usage)\` | $(prom_query 'max(vllm:gpu_cache_usage_perc{namespace="vllm"})') |
EOF
)
fi

echo "${PROM_BLOCK}" > "${WORKDIR}/prom-block.md"

export CHAT_URL MODEL_PATH BASELINE_REPLICAS MAX_REPLICAS BASELINE_GPU MAX_GPU
export DURATION_SEC CONCURRENCY
export SCALE_UP_AT="${SCALE_UP_AT:-}" COLD_START_SEC NEW_POD="${NEW_POD:-}"

REPORT=$(python3 - "${WORKDIR}/client-stats.json" "${TIMELINE}" "${WORKDIR}/prom-block.md" <<'PY'
import json
import os
import sys
from pathlib import Path

stats = json.loads(Path(sys.argv[1]).read_text())
timeline = Path(sys.argv[2]).read_text().rstrip()
prom_block = Path(sys.argv[3]).read_text().rstrip()

def fmt(v):
    if isinstance(v, float):
        return f"{v:.0f}" if v == v else "nan"
    return str(v)

print(f"""# Load test autoscale report ({os.environ.get('TF_ENVIRONMENT', 'dev')})

## Configuration
- Duration: {os.environ.get('DURATION_SEC', '?')}s
- Concurrency: {os.environ.get('CONCURRENCY', '?')}
- Endpoint: {os.environ.get('CHAT_URL', '?')}
- Model: {os.environ.get('MODEL_PATH', '?')}

## Client metrics (streaming)
| Metric | Value |
|--------|-------|
| Completed | {stats.get('completed', 0)} |
| Success / Fail | {stats.get('success', 0)} / {stats.get('fail', 0)} |
| Error rate | {stats.get('error_rate', 0):.4f} |
| TTFT p50 / p95 (ms) | {fmt(stats.get('ttft_p50_ms'))} / {fmt(stats.get('ttft_p95_ms'))} |
| E2E p50 / p95 (ms) | {fmt(stats.get('e2e_p50_ms'))} / {fmt(stats.get('e2e_p95_ms'))} |

## Autoscale timeline
- Baseline replicas: {os.environ.get('BASELINE_REPLICAS', '?')}
- Peak replicas observed: {os.environ.get('MAX_REPLICAS', '?')}
- Baseline GPU nodes: {os.environ.get('BASELINE_GPU', '?')}
- Peak GPU nodes: {os.environ.get('MAX_GPU', '?')}
- Scale-up detected (desired > baseline): {os.environ.get('SCALE_UP_AT') or 'not observed'}
- New pod cold-start (Pending→Ready): {os.environ.get('COLD_START_SEC', 'n/a')} sec ({os.environ.get('NEW_POD') or 'none'})

### Snapshots
\`\`\`
{timeline}
\`\`\`

## Prometheus (server-side, during/after load)
{prom_block}

## Spot interruption (manual validation)
1. Ensure Spot NodePool \`g5-spot\` is applied (prod burst).
2. Cordon + terminate one **Spot** GPU node during low traffic; record recovery time.
3. Confirm \`KarpenterSpotInterruptionRate\` alert and PDB keeps min replicas on On-Demand.
4. See \`docs/load-test.md\` for full checklist.

## SLO targets (prod)
- TTFT p95 < 2s · E2E p95 < 10s · error rate < 1%
""")
PY
)

echo ""
echo "${REPORT}"

if [[ -n "${LOAD_TEST_REPORT}" ]]; then
  mkdir -p "$(dirname "${LOAD_TEST_REPORT}")"
  echo "${REPORT}" > "${LOAD_TEST_REPORT}"
  echo "Report written to ${LOAD_TEST_REPORT}"
fi

FAIL=0
ERROR_RATE=$(python3 -c "import json; print(json.load(open('${WORKDIR}/client-stats.json'))['error_rate'])")
if python3 -c "import sys; sys.exit(0 if float('${ERROR_RATE}') < 0.05 else 1)"; then
  echo "PASS client error rate < 5%"
else
  echo "WARN client error rate >= 5% (may be expected under heavy load)"
  FAIL=1
fi

if [[ "${ENABLE_KEDA:-0}" == "1" ]]; then
  if [[ -n "${SCALE_UP_AT}" ]] || [[ "${MAX_REPLICAS}" -gt "${BASELINE_REPLICAS}" ]]; then
    echo "PASS KEDA scale-up observed (replicas ${BASELINE_REPLICAS} -> ${MAX_REPLICAS})"
  else
    echo "WARN KEDA scale-up not observed — increase CONCURRENCY/DURATION or lower thresholds"
    FAIL=1
  fi
else
  echo "Note: ENABLE_KEDA!=1 — skipping scale-up check"
fi

exit "${FAIL}"
