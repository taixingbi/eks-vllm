# Gateway / Router (Phases 0–12)

Multi-replica routing for vLLM on EKS. Phases **0–9** are implemented in this repo; **10–12** are documented for future work.

## Phase map

| Phase | Name | Status | Config |
|-------|------|--------|--------|
| **0** | Baseline | Done | ALB → `vllm-qwen` Service → round-robin |
| **1** | Session router | Implemented | `ROUTER_ROUTING_LOGIC=session`, header `X-Session-Id` |
| **2** | Router HA | Implemented | prod: 2 replicas, PDB, required zone anti-affinity + `DoNotSchedule` spread |
| **3** | Load-aware | Implemented | `--engine-stats-interval 15`, `--request-stats-window 60`; lowest-QPS fallback when no session |
| **4** | GPU-aware | Partial | Engine stats scrape includes GPU cache / queue metrics via vLLM `/metrics` |
| **5** | Failure handling | Implemented | Router probes; K8s discovery skips NotReady pods; client retry guidance below |
| **6** | Observability | Implemented | Router `/metrics`, ServiceMonitor, `prometheus.io` annotations |
| **7** | Client contract | Documented | Required header for chat; fallback behavior |
| **8** | Prefix/KV-aware | Implemented (prod) | prod default `ROUTER_ROUTING_LOGIC=prefixaware` |
| **9** | LMCache | Implemented (opt-in) | prod default; dev `DEV_ENABLE_LMCACHE=1` |
| **10** | Multi-model | Future | — |
| **11** | Platform gateway | Implemented | Kong + AWS WAF (prod); `DEV_ENABLE_PLATFORM_GATEWAY=1` |
| **12** | Cost / SLA routing | Future | Tenant priority |

## Architecture

### Phases 1–9 (router only)

```text
Client  →  ALB  →  vllm-router  →  vllm-qwen pods (KEDA-scaled)
                      ↑
              K8s pod discovery (app=vllm-qwen)
              Optional LMCache controller port (phase 9)
```

### Phase 11 (platform gateway + WAF)

WAF is **attached to the ALB**, not a separate hop.

```text
Client  →  ALB + AWS WAF  →  Kong  →  vllm-router  →  vllm-qwen pods
```

| Layer | Role |
|-------|------|
| **ALB + AWS WAF** | Public edge — TLS, idle timeout 300s, IP rate limits, managed rules (prod: count mode initially) |
| **Kong** | Platform API gateway — API keys, rate limit, body size, proxy timeouts |
| **vllm-router** | Session / GPU routing |
| **vLLM pods** | Model serving |

Direct debug path (bypass Kong): `kubectl port-forward -n vllm svc/vllm-router 8000:8000`

**Naming:** `make install-gateway` = router + LMCache (phases 1–9). `make install-platform-gateway` = Kong (phase 11).

## Enable flags

| Environment | Router | LMCache | Routing logic |
|-------------|--------|---------|---------------|
| **prod** | always | yes (phase 9) | `kvaware` |
| **dev** (default) | off | off | — |
| **dev** | `DEV_ENABLE_ROUTER=1` | off | `session` |
| **dev** | `DEV_ENABLE_ROUTER=1` + `DEV_ENABLE_LMCACHE=1` | on | `kvaware` |

### Phase 11 — Platform gateway

| Environment | Platform gateway | WAF | Requires |
|-------------|------------------|-----|----------|
| **prod** | on (with ALB) | on | router always on |
| **dev** | `DEV_ENABLE_PLATFORM_GATEWAY=1` | off | `DEV_ENABLE_ALB=1` + `DEV_ENABLE_ROUTER=1` |

Override tunables: `GATEWAY_RATE_LIMIT_PER_MINUTE` (default 60), `GATEWAY_MAX_BODY_MB` (default 10).

**Rate limit caveat:** Kong `local` policy is **per Kong pod**. With 2 replicas and limit 60/min, effective ceiling ≈ 120/min. Use Redis-backed policy for global limits (future).

Override routing: `ROUTER_ROUTING_LOGIC=prefixaware|session|kvaware`

Override session header: `ROUTER_SESSION_KEY=X-Session-Id` (default)

### Local commands

```bash
# Phase 1 only (session routing, 1 router replica)
DEV_ENABLE_ROUTER=1 make install-router TF_ENVIRONMENT=dev

# Phases 1–9 (session + LMCache + kvaware)
DEV_ENABLE_ROUTER=1 DEV_ENABLE_LMCACHE=1 make install-gateway TF_ENVIRONMENT=dev

# Phase 11 — Kong platform gateway (requires ALB + router on dev)
DEV_ENABLE_ALB=1 DEV_ALB_HTTP_ONLY=1 DEV_ENABLE_ROUTER=1 DEV_ENABLE_PLATFORM_GATEWAY=1 \
  PLATFORM_GATEWAY_API_KEY=test-key make install-platform-gateway TF_ENVIRONMENT=dev

# Full deploy with gateway (prod includes router + LMCache + Kong + WAF automatically)
make deploy-k8s TF_ENVIRONMENT=prod
```

## Client contract (phase 7 + 11)

### Session routing (phase 7)

Send a **stable session id** per conversation or user:

```http
X-Session-Id: user-abc-123
Content-Type: application/json
```

### API authentication (phase 11)

When platform gateway is enabled, `/v1/*` requires an API key:

```http
X-API-Key: <your-key>
# OR
Authorization: Bearer <your-key>

X-Session-Id: user-abc-123
Content-Type: application/json
```

| Route | Auth | Purpose |
|-------|------|---------|
| `GET /health` | none | Kong liveness (ALB health check target) |
| `GET /ready` | none | Full stack readiness (proxies to router `/health`) |
| `/v1/*` | API key | OpenAI-compatible API |

Prod keys: AWS Secrets Manager `qwen-vllm/api-gateway-keys` as `{"keys":["key1","key2"]}`.

Dev: set `PLATFORM_GATEWAY_API_KEY` at deploy time (placeholder `dev-change-me` if unset).

### Session headers (phase 7)

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
| `scripts/apply-router.sh` | Incremental router apply |
| `kubernetes/gateway/kong-dbless-config.yaml.template` | Kong declarative config template |
| `scripts/install-platform-gateway.sh` | Kong Helm install |
| `scripts/apply-platform-gateway.sh` | Incremental platform gateway apply |
| `scripts/build-kong-config.sh` | Patch Kong config with API keys |
| `scripts/lib/env.sh` | `ENABLE_ROUTER`, `ENABLE_LMCACHE`, `ENABLE_PLATFORM_GATEWAY`, `ENABLE_WAF` |

## Troubleshooting

### Router rollout timeout

The router returns **503 on `/health`** until vLLM backends are Ready (production-stack behavior). Symptoms:

```
Waiting for deployment "vllm-router" rollout to finish: 0 of 1 updated replicas are available...
```

**Fix:** Ensure vLLM pods are Running first (`kubectl get pods -n vllm -l app=vllm-qwen`). `deploy-k8s.sh` waits for vLLM before the router.

If the router pod is **CrashLoopBackOff**, check logs for unrecognized CLI flags and pin `VLLM_ROUTER_TAG` (default `v0.1.11`).

### Disk pressure / ErrImagePull on system nodes

The router image (`lmcache/lmstack-router`) includes PyTorch/CUDA layers (~several GB). Pulling it on system nodes with a small root volume causes:

```
Evicted: The node was low on resource: ephemeral-storage
ErrImagePull: no space left on device
```

**Fix:**

1. System nodes use **80 GiB** root volume (see `system_node_volume_size` in Terraform). Run `make apply` to roll nodes if upgrading from default 20 GiB.
2. Router pods are pinned to `nodeSelector: role=system` (not GPU nodes).
3. Clean up and retry:

```bash
kubectl delete pods -n vllm -l app=vllm-router --field-selector=status.phase=Failed
# If node still has disk-pressure taint, cycle the system node (ASG) or drain + terminate
kubectl get nodes -l role=system
make apply-router TF_ENVIRONMENT=dev DEV_ENABLE_ROUTER=1
```

```bash
kubectl logs -n vllm deploy/vllm-router --tail=80
kubectl describe pod -n vllm -l app=vllm-router
```

## Future phases (12)

- **12 Cost/SLA:** tenant headers, priority queues, SLO-based routing

See [`docs/design.md`](design.md) Route B: ALB + WAF → Kong → router → vLLM.
