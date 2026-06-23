#!/usr/bin/env bash
# Lightweight load test + SLO spot-check against a running vLLM endpoint.
# Usage:
#   kubectl port-forward -n vllm svc/vllm-qwen 8000:8000 &
#   MODEL_PATH=/models/Qwen2.5-0.5B-Instruct ./scripts/load-test-slo.sh
#   INFERENCE_URL=https://your-host/v1 ./scripts/load-test-slo.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

INFERENCE_URL="${INFERENCE_URL:-http://127.0.0.1:8000/v1}"
# MODEL_PATH exported by env.sh from MODEL_NAME; override if needed.
REQUESTS="${REQUESTS:-20}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_TTFT_MS="${MAX_TTFT_MS:-2000}"
MAX_E2E_MS="${MAX_E2E_MS:-10000}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"

if [[ -z "${MODEL_PATH}" ]]; then
  echo "MODEL_PATH is required (e.g. /models/Qwen3-8B)"
  exit 1
fi

echo "Load test: ${REQUESTS} requests, concurrency=${CONCURRENCY}"
echo "Endpoint: ${INFERENCE_URL}/chat/completions"
echo "Model: ${MODEL_PATH}"
echo "SLO targets: TTFT p95 < ${MAX_TTFT_MS}ms, e2e p95 < ${MAX_E2E_MS}ms, error rate < ${MAX_ERROR_RATE}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

do_request() {
  local id=$1
  local start end http_code ttft_ms e2e_ms
  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  http_code=$(curl -sS -o "${tmpdir}/resp-${id}.json" -w "%{http_code}" \
    "${INFERENCE_URL}/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_PATH}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in one word.\"}],\"max_tokens\":16,\"stream\":false}" \
    --max-time 120) || http_code="000"
  end=$(python3 -c 'import time; print(int(time.time()*1000))')
  e2e_ms=$((end - start))
  # vLLM does not return TTFT in non-streaming; use e2e as upper bound for this smoke test.
  ttft_ms=${e2e_ms}
  echo "${http_code} ${ttft_ms} ${e2e_ms}" > "${tmpdir}/timing-${id}.txt"
}

export -f do_request
export INFERENCE_URL MODEL_PATH tmpdir

seq 1 "${REQUESTS}" | xargs -P "${CONCURRENCY}" -I {} bash -c 'do_request "$@"' _ {}

ok=0
fail=0
while IFS= read -r line; do
  code=$(echo "$line" | awk '{print $1}')
  if [[ "${code}" == "200" ]]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
done < <(cat "${tmpdir}"/timing-*.txt)

error_rate=$(python3 - <<PY
ok, fail, total = ${ok}, ${fail}, ${REQUESTS}
print(fail / total if total else 1.0)
PY
)

p95_e2e=$(python3 - <<PY
import glob
vals = []
for p in glob.glob("${tmpdir}/timing-*.txt"):
    with open(p) as f:
        parts = f.read().split()
        if len(parts) >= 3:
            vals.append(int(parts[2]))
vals.sort()
if not vals:
    print(999999)
else:
    idx = max(0, int(len(vals) * 0.95) - 1)
    print(vals[idx])
PY
)

echo ""
echo "Results: success=${ok} fail=${fail} error_rate=${error_rate}"
echo "Approx p95 e2e latency: ${p95_e2e}ms (non-streaming upper bound)"

failed=0
if python3 -c "import sys; sys.exit(0 if float('${error_rate}') < float('${MAX_ERROR_RATE}') else 1)"; then
  echo "PASS error rate"
else
  echo "FAIL error rate >= ${MAX_ERROR_RATE}"
  failed=1
fi

if [[ "${p95_e2e}" -lt "${MAX_E2E_MS}" ]]; then
  echo "PASS e2e p95"
else
  echo "FAIL e2e p95 >= ${MAX_E2E_MS}ms"
  failed=1
fi

echo ""
echo "For true TTFT p95, use Prometheus vllm:ttft:p95 during sustained load."
exit "${failed}"
