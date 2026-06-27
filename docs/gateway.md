# Gateway / Router (Phases 0–12)

Multi-replica routing for vLLM on EKS. Phases **0–9** are implemented in this repo; **10–12** are documented for future work.

## Phase map

| Phase | Name | Status | Config |
|-------|------|--------|--------|
| **0** | Baseline | Done | ALB → `vllm-qwen` Service → round-robin |
| **1** | Session router | Implemented | `ROUTER_ROUTING_LOGIC=session`, header `X-Session-Id` |
| **2** | Router HA | Implemented | prod: 2 replicas, PDB, anti-affinity |
| **3** | Load-aware | Implemented | `--engine-stats-interval 15`, `--request-stats-window 60`; lowest-QPS fallback when no session |
| **4** | GPU-aware | Partial | Engine stats scrape includes GPU cache / queue metrics via vLLM `/metrics` |
| **5** | Failure handling | Implemented | Router probes; K8s discovery skips NotReady pods; client retry guidance below |
| **6** | Observability | Implemented | Router `/metrics`, ServiceMonitor, `prometheus.io` annotations |
| **7** | Client contract | Documented | Required header for chat; fallback behavior |
| **8** | Prefix/KV-aware | Implemented (prod) | prod default `ROUTER_ROUTING_LOGIC=prefixaware` |
| **9** | LMCache | Implemented (opt-in) | prod default; dev `DEV_ENABLE_LMCACHE=1` |
| **10** | Multi-model | Future | — |
| **11** | Auth / rate limit | Future | AWS WAF, API keys |
| **12** | Cost / SLA routing | Future | Tenant priority |

## Architecture (phases 1–9 enabled)

```text
Client  →  ALB  →  vllm-router  →  vllm-qwen pods (KEDA-scaled)
                      ↑
              K8s pod discovery (app=vllm-qwen)
              Optional LMCache controller port (phase 9)
```

Direct debug path (bypass router): `kubectl port-forward -n vllm svc/vllm-qwen 8000:8000`

## Enable flags

| Environment | Router | LMCache | Routing logic |
|-------------|--------|---------|---------------|
| **prod** | always | yes (phase 9) | `kvaware` |
| **dev** (default) | off | off | — |
| **dev** | `DEV_ENABLE_ROUTER=1` | off | `session` |
| **dev** | `DEV_ENABLE_ROUTER=1` + `DEV_ENABLE_LMCACHE=1` | on | `kvaware` |

Override routing: `ROUTER_ROUTING_LOGIC=prefixaware|session|kvaware`

Override session header: `ROUTER_SESSION_KEY=X-Session-Id` (default)

### Local commands

```bash
# Phase 1 only (session routing, 1 router replica)
DEV_ENABLE_ROUTER=1 make install-router TF_ENVIRONMENT=dev

# Phases 1–9 (session + LMCache + kvaware)
DEV_ENABLE_ROUTER=1 DEV_ENABLE_LMCACHE=1 make install-gateway TF_ENVIRONMENT=dev

# Full deploy with gateway (prod includes router + LMCache automatically)
make deploy-k8s TF_ENVIRONMENT=prod
```

## Client contract (phase 7)

Send a **stable session id** per conversation or user:

```http
X-Session-Id: user-abc-123
Content-Type: application/json
```

| Header | Required | Behavior |
|--------|----------|----------|
| `X-Session-Id` | Recommended for chat | Same value → same backend pod (phase 1) |
| *(omitted)* | Allowed | Router picks lowest-QPS backend (phases 3–4 fallback) |

### Retry rules (phase 5)

- **Do retry** on connection errors or HTTP 502/503 **before** streaming starts.
- **Do not retry** after the first token in a streaming response (duplicate output risk).
- If a backend pod is evicted, start a **new session id** or accept cold-cache latency on remap.

## LMCache (phase 9)

LMCache enables cross-pod KV reuse when using a **vLLM build with LMCache KV connector** support.

This repo adds:

- ConfigMap [`kubernetes/vllm/lmcache-config.yaml`](../kubernetes/vllm/lmcache-config.yaml)
- vLLM pod ports `8001` (worker) and `9000` (controller)
- Router `--lmcache-controller-port 9000`

If your ECR `v0.8.4` image lacks LMCache, either:

1. Set `DEV_ENABLE_LMCACHE` unset / disable on prod via `ENABLE_LMCACHE=0` in CI, or
2. Switch to an LMCache-enabled vLLM image (e.g. `lmcache/vllm-openai`) in a future image bump.

With LMCache disabled, phases **1–8** still work via per-pod prefix caching + router logic.

## Validation

### Sticky session (phase 1)

```bash
ENDPOINT=http://127.0.0.1:8000/v1
MODEL=/models/Qwen2.5-7B-Instruct/v1

for i in 1 2 3; do
  curl -s -H "X-Session-Id: test-user-a" "${ENDPOINT}/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi ${i}\"}],\"max_tokens\":8}"
done

# Same backend pod in vLLM logs:
kubectl logs -n vllm -l app=vllm-qwen --tail=20
```

### Router health

```bash
kubectl get deploy,svc,pdb -n vllm -l app=vllm-router
kubectl logs -n vllm deploy/vllm-router --tail=50
```

### Prometheus (phase 6)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Query router metrics if exported; vLLM metrics unchanged on GPU pods
```

### Multi-replica + KEDA

Use with `DEV_ENABLE_KEDA=1`. Router discovers new pods automatically when KEDA scales out.

## Files

| File | Purpose |
|------|---------|
| `kubernetes/vllm/router.yaml` | Router Deployment, Service, PDB |
| `kubernetes/vllm/router-rbac.yaml` | Pod discovery RBAC |
| `kubernetes/vllm/lmcache-config.yaml` | LMCache config (phase 9) |
| `kubernetes/monitoring/servicemonitor-router.yaml` | Prometheus scrape |
| `scripts/apply-router.sh` | Incremental gateway apply |
| `scripts/lib/env.sh` | `ENABLE_ROUTER`, `ENABLE_LMCACHE`, routing logic |

## Troubleshooting

### Router rollout timeout

The router returns **503 on `/health`** until vLLM backends are Ready (production-stack behavior). Symptoms:

```
Waiting for deployment "vllm-router" rollout to finish: 0 of 1 updated replicas are available...
```

**Fix:** Ensure vLLM pods are Running first (`kubectl get pods -n vllm -l app=vllm-qwen`). `deploy-k8s.sh` waits for vLLM before the router.

If the router pod is **CrashLoopBackOff**, check logs for unrecognized CLI flags and pin `VLLM_ROUTER_TAG` (default `v0.1.11`).

```bash
kubectl logs -n vllm deploy/vllm-router --tail=80
kubectl describe pod -n vllm -l app=vllm-router
```

## Future phases (10–12)

- **10 Multi-model:** multiple Deployments + router model aliases
- **11 Auth:** ALB WAF, `VLLM_API_KEY`, rate limits
- **12 Cost/SLA:** tenant headers, priority queues, SLO-based routing

See [`docs/design.md`](design.md) Route B: ALB → gateway → vLLM.
