# Production HA and SLO targets for vLLM on EKS.

## High availability (prod defaults)

| Control | Dev | Prod | Purpose |
|---------|-----|------|---------|
| PDB `minAvailable` | 0 | 1 | Block draining all vLLM pods during upgrades / node disruption |
| Rolling `maxSurge` | 0 | 1 | Start new pod before terminating old |
| Rolling `maxUnavailable` | 1 | 0 | Never drop below desired capacity during rollout |
| `startupProbe` | 90 × 10s | 30 × 10s | Wait for model load before ready |
| `readinessProbe` | `/health` | `/health` | Only route traffic when healthy |
| `preStop` sleep | 15s | 30s | Drain in-flight requests before SIGTERM |
| `terminationGracePeriodSeconds` | 120 | 120 | Match ALB idle timeout + long generations |
| Topology spread (zone) | `DoNotSchedule`, maxSkew 1 | same | Require balanced AZ placement; pod stays Pending until another AZ has capacity |
| Router / Kong anti-affinity | required (zone) | same | At most one router/Kong pod per AZ when replicas ≥ 2 |
| On-Demand NodePool weight | 100 | 100 | Baseline GPU nodes |
| Spot NodePool weight | 10 | 10 | Burst only; interruption via Karpenter SQS |

Manifest: `kubernetes/vllm/deployment.yaml` · patched in `scripts/patch-manifests.sh`.

### Spot interruption

- Terraform: SQS + EventBridge for Spot interruption / rebalance → Karpenter
- Helm: `settings.interruptionQueue` on Karpenter
- EFS model cache: faster reschedule after node loss (no full re-download)
- **Baseline replicas on On-Demand**; Spot for KEDA burst only
- `preStop` + 120s grace: time to finish streaming responses when node is cordoned

## Service level objectives (prod)

| SLI | Target | Prometheus | Alert |
|-----|--------|------------|-------|
| TTFT p95 | < 2s | `vllm:ttft:p95` | `VLLMSLOTTFTBreached` |
| End-to-end p95 | < 10s | `vllm:e2e_latency:p95` | `VLLMSLOLatencyBreached` |
| Error rate | < 1% | `vllm:error_rate:ratio` | `VLLMSLOErrorRateBreached` |
| Availability | ≥ 99.5% ready | `vllm:ready_replicas:ratio` | `VLLMSLOAvailabilityBreached` |

Rules: `kubernetes/monitoring/prometheus-rules.yaml`  
Availability alerts require **kube-state-metrics** (prod full Prometheus stack; disabled on dev slim stack).

## Load testing

**SLO gate** (streaming TTFT, client p95):

```bash
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000 &
make load-test-slo TF_ENVIRONMENT=prod
```

**Autoscale evidence** (sustained load + replica/GPU timeline + report):

```bash
make load-test-autoscale TF_ENVIRONMENT=prod
LOAD_TEST_REPORT=artifacts/load-test-report.md make load-test-autoscale TF_ENVIRONMENT=prod
```

Full checklist: **`docs/load-test.md`**

## Release checklist (prod)

- [ ] 2+ On-Demand replicas Running across AZs (`kubectl get pods -n vllm -o wide` — distinct zones)
- [ ] PDB `minAvailable: 1` (use `2` when running 3+ replicas)
- [ ] No vLLM pods Pending due to topology spread (provision GPU nodes in each AZ if needed)
- [ ] Rolling update with `maxUnavailable: 0`
- [ ] Prometheus SLO alerts firing dry-run / no false positives
- [ ] `make load-test-slo TF_ENVIRONMENT=prod` pass against staging endpoint
- [ ] `make load-test-autoscale TF_ENVIRONMENT=prod` — KEDA scale-up observed; report archived
- [ ] Spot interruption runbook reviewed (Karpenter replaces node; EFS cache warm)
