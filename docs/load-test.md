# Load testing and autoscaling evidence

Validate SLOs and prove KEDA/Karpenter behavior before prod release.

## Prerequisites

| Requirement | Dev | Prod |
|-------------|-----|------|
| vLLM Running | `kubectl get pods -n vllm` | same |
| Prometheus (KEDA triggers) | `DEV_ENABLE_PROMETHEUS=1` | always |
| KEDA ScaledObject | `DEV_ENABLE_KEDA=1` | always |
| Ingress / ALB (optional) | `DEV_ENABLE_ALB=1` | HTTPS + WAF |
| Platform gateway (optional) | `DEV_ENABLE_PLATFORM_GATEWAY=1` | Kong + API keys |

Set `TF_ENVIRONMENT` and ensure `kubectl` context matches the cluster.

## 1. SLO smoke test (short)

Streaming TTFT + client-side p95 latencies. Default: 40 requests, concurrency 8.

```bash
# Direct to vLLM (port-forward)
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000 &
INFERENCE_URL=http://127.0.0.1:8000/v1 make load-test-slo TF_ENVIRONMENT=dev

# Via ALB + Kong (dev API key from ConfigMap)
make load-test-slo TF_ENVIRONMENT=dev

# Via router
kubectl port-forward -n vllm svc/vllm-router 8000:8000 &
INFERENCE_URL=http://127.0.0.1:8000/v1 make load-test-slo TF_ENVIRONMENT=dev
```

**Pass criteria (defaults):**

| SLI | Target | Env override |
|-----|--------|--------------|
| TTFT p95 | < 2000 ms | `MAX_TTFT_MS` |
| E2E p95 | < 10000 ms | `MAX_E2E_MS` |
| Error rate | < 1% | `MAX_ERROR_RATE` |

Tune load: `REQUESTS=60 CONCURRENCY=12 MAX_TOKENS=64`.

**Server-side metrics** (optional — auto-printed if Prometheus reachable):

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
PROMETHEUS_URL=http://127.0.0.1:9090 make load-test-slo TF_ENVIRONMENT=dev
```

Watch: `vllm:ttft:p95`, `vllm:e2e_latency:p95`, `vllm:generation_tps:sum`, `vllm:queue_depth:sum`.

## 2. Autoscale evidence (sustained load)

Runs **180s** sustained streaming load (default concurrency 10), polls replicas/HPA/GPU nodes every 15s, and prints a markdown report.

```bash
DEV_ENABLE_KEDA=1 make load-test-autoscale TF_ENVIRONMENT=dev

# Save report for release checklist
LOAD_TEST_REPORT=artifacts/load-test-$(date +%Y%m%d).md \
  make load-test-autoscale TF_ENVIRONMENT=dev
```

**Increase pressure** if scale-up is not observed (min replicas may already satisfy load):

```bash
DURATION_SEC=300 CONCURRENCY=16 MAX_TOKENS=256 \
  make load-test-autoscale TF_ENVIRONMENT=dev
```

**Pass criteria:**

| Check | Expected |
|-------|----------|
| Client error rate | < 5% under sustained load |
| KEDA scale-up | `desired` replicas > baseline (when `ENABLE_KEDA=1`) |
| GPU nodes | Karpenter adds nodes if pods stay Pending |
| Cold start | Report records Pending→Ready for new pod (model load time) |

KEDA triggers (any fires → scale up): see `kubernetes/vllm/keda-scaledobject.yaml` and patched thresholds in `scripts/patch-manifests.sh`.

## 3. Spot interruption (manual)

Not automated — run once per environment before relying on Spot burst:

1. Confirm Spot NodePool `g5-spot` is deployed (prod; dev optional).
2. Baseline: 2+ On-Demand replicas Running, PDB active.
3. Identify a **Spot** GPU node: `kubectl get nodes -l karpenter.sh/capacity-type=spot`.
4. Cordon and drain: `kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
5. Record: time to new node Ready, time to vLLM pod Ready, any SLO breach during drain.
6. Verify alerts: `KarpenterSpotInterruptionRate`, `VLLMSLO*` (no sustained breach).

EFS model cache should reduce cold-start after reschedule.

## 4. Release checklist integration

Before prod cutover (`docs/production-ha-slo.md`):

- [ ] `make load-test-slo TF_ENVIRONMENT=prod` — PASS against staging endpoint
- [ ] `make load-test-autoscale TF_ENVIRONMENT=prod` — scale-up observed, report archived
- [ ] Spot interruption runbook executed on staging
- [ ] Grafana dashboard imported (`kubernetes/monitoring/grafana-dashboard-vllm.json`)
- [ ] KEDA ScaledObject `Ready`: `kubectl get scaledobject -n vllm`

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/load-test-slo.sh` | Short SLO gate with streaming TTFT |
| `scripts/load-test-autoscale.sh` | Sustained load + KEDA/Karpenter timeline |
| `scripts/lib/load_test_runner.py` | Concurrent client (streaming TTFT measurement) |
| `scripts/lib/load-test-common.sh` | Endpoint resolution, Prometheus, k8s snapshots |
