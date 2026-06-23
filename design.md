# eks-vllm Dev Roadmap

**Philosophy:** boring first, optimize later. Steps 1–5 are the minimal dev path; Steps 6–8 are optional flags. Steps 9–10 are out of scope for `dev`.

---

## Steps

| Step | Goal | How to enable (dev) |
|------|------|---------------------|
| **1** | EKS cluster | Push to `dev` or `make apply TF_ENVIRONMENT=dev` |
| **2** | GPU nodes | Karpenter NodePool (`g5.2xlarge` default on dev) |
| **3** | vLLM 0.5B | `Qwen/Qwen2.5-0.5B-Instruct`, conservative vLLM args, 1 replica |
| **4** | curl succeeds | `kubectl port-forward` → `/v1/models` or `/v1/chat/completions` |
| **5** | CI smoke test | `deploy.yml` — rollout wait 45m + dev smoke test |
| **6** | Prometheus | `DEV_ENABLE_PROMETHEUS=1` → `make install-prometheus TF_ENVIRONMENT=dev` |
| **7** | KEDA | `DEV_ENABLE_KEDA=1` → `make install-keda TF_ENVIRONMENT=dev` (auto-enables Prometheus) |
| **8** | ALB | `DEV_ENABLE_ALB=1` → `make install-alb TF_ENVIRONMENT=dev` |
| **9** | Qwen 7B/8B | Change `MODEL_NAME` + instance type; not dev default |
| **10** | Production | `main` branch → `prod` environment |

### Step 6 — Prometheus

- GitHub: set repo/env var `DEV_ENABLE_PROMETHEUS=1`, push or re-run Deploy
- Local: `make install-prometheus TF_ENVIRONMENT=dev`
- Slim stack on dev (no Grafana/Alertmanager/node-exporter)

### Step 7 — KEDA

- Requires Step 6 (Prometheus scraping `vllm:*` metrics)
- Scale-out triggers (OR): **waiting queue** (primary), **max GPU KV cache**, **TTFT p95** (tertiary)
- `tokens/sec` → Grafana + alerts only, **not** a KEDA trigger
- Recording rules: `vllm:queue_depth:sum`, `vllm:ttft:p95`, `vllm:e2e_latency:p95`, `vllm:generation_tps:sum`

### Step 8 — ALB

| Mode | Flags | Notes |
|------|-------|-------|
| HTTP (dev) | `DEV_ENABLE_ALB=1` + `DEV_ALB_HTTP_ONLY=1` | Port 80, ALB DNS — no ACM or hostname |
| HTTPS | `DEV_ENABLE_ALB=1` + secrets `ACM_CERTIFICATE_ARN`, `INFERENCE_HOSTNAME` | Prod-style TLS |

**Security note:** public ALB exposes the raw vLLM API. For prod, prefer internal ClusterIP (Route A) or ALB → LLM Gateway → vLLM (Route B). See README.

### Recovery

- Stale GPU nodes / NodeClaims: `make fix-gpu TF_ENVIRONMENT=dev`
- Workflow: Actions → Reset → `fix-gpu` | `redeploy-k8s` | `reset-k8s`

---

## Status Tracker

Two layers: **code/CI ready** vs **validated on dev cluster**.

| Step | Goal | Code / CI | Dev validated |
|------|------|-----------|---------------|
| 1 | EKS | ✅ `terraform/environments/dev` + Deploy workflow | ⚠️ Cluster existed (`qwen-vllm-dev`); recent destroy may leave partial state (ECR/IGW deps) |
| 2 | GPU node | ✅ Karpenter NodePool `g5.2xlarge` | ⚠️ Flaky — NodeClaim / `disrupted` taint → Pending |
| 3 | vLLM 0.5B | ✅ `Qwen2.5-0.5B-Instruct` + conservative args | ⚠️ Pod reached Started; rollout Evicted — not stable 1/1 Running |
| 4 | curl | ✅ README + port-forward docs | ❌ Not confirmed end-to-end (CI model path fixed; local curl blocked by Pending) |
| 5 | CI smoke test | ✅ `deploy.yml` rollout + smoke test | ❌ Pipeline not consistently green |
| 6 | Prometheus | ✅ `DEV_ENABLE_PROMETHEUS=1` | ⚠️ Confirm `vllm:*` series in PromQL |
| 7 | KEDA | ✅ `DEV_ENABLE_KEDA=1` + production triggers | ⚠️ Confirm ScaledObject Ready + `vllm:ttft:p95` recording rule |
| 8 | ALB | ✅ `DEV_ENABLE_ALB=1`, `DEV_ALB_HTTP_ONLY=1` | ⚠️ Confirm `kubectl get ingress` ADDRESS + HTTP curl |
| 9 | Qwen 7B/8B | ❌ Dev still defaults to 0.5B | ❌ Not started |
| 10 | Production | ❌ `main` / prod only | — not a dev goal |

**Legend:** ✅ done · ⚠️ partial / needs verification · ❌ not done

---

## Dev Defaults (Steps 1–5 minimal path)

Skipped unless flags set: ALB, KEDA, Prometheus, External Secrets, Ingress.

| Setting | Dev value |
|---------|-----------|
| Model | `Qwen/Qwen2.5-0.5B-Instruct` |
| Instance | `g5.2xlarge` |
| Replicas | 1 |
| PDB `minAvailable` | 0 |
| Rollout `maxSurge` | 0 |

---

## Pinned add-on versions

All Helm installs use `--version` from **`scripts/lib/chart-versions.sh`** (sourced by `env.sh`). CI can override via GitHub repository variables.

| Component | Default version |
|-----------|-----------------|
| Karpenter | `1.0.8` |
| ALB Controller | `1.8.2` |
| AWS EFS CSI | `3.1.7` |
| kube-prometheus-stack | `86.2.3` |
| KEDA | `2.16.1` |
| External Secrets | `2.6.0` |
| NVIDIA device plugin | `0.14.5` |

---

## Policy gates

| Phase | Status | Tools |
|-------|--------|-------|
| P0 | ✅ | `terraform fmt/validate`, gitleaks |
| P1 | ✅ | tflint, checkov (`.checkov.yml`) |
| P2 | ❌ | kubeconform, conftest/OPA |
| P3 | ❌ | Trivy image scan |

CI: `.github/workflows/policy.yml` · Local: `make lint-terraform`

---

## Production HA & SLO (Step 10)

| Item | Status |
|------|--------|
| PDB + rolling update (prod) | ✅ |
| startup / readiness / liveness probes | ✅ |
| preStop + termination grace | ✅ |
| Spot interruption (SQS + Karpenter + EFS) | ✅ |
| On-Demand preferred over Spot (NodePool weight) | ✅ |
| SLO alerts (`VLLMSLO*`) | ✅ |
| Load test script | ✅ `scripts/load-test-slo.sh` |

Details: **`docs/production-ha-slo.md`**

---

## Next actions

1. Finish clean destroy or fresh `make apply` on dev
2. Set GitHub vars: `DEV_ENABLE_PROMETHEUS=1`, `DEV_ENABLE_KEDA=1` (optional: `DEV_ENABLE_ALB=1`, `DEV_ALB_HTTP_ONLY=1`)
3. Stabilize Steps 1–5 (1/1 Running + green CI smoke test)
4. Verify Steps 6–8 in order
5. Step 9+ on separate branch / prod when quota and stability allow
