# Qwen 8B + vLLM on EKS (G5)

Production-ready Terraform and Kubernetes manifests for serving **Qwen3-8B** via vLLM on AWS EKS with G5 GPU nodes, Karpenter autoscaling, ALB ingress, EFS model cache, and KEDA-driven replica scaling.

## Architecture

- **Baseline:** 2× On-Demand `g5.4xlarge` (1 vLLM replica per GPU, spread across AZs)
- **Burst:** Karpenter Spot `g5.4xlarge` pool (up to ~8 nodes)
- **Scaling:** KEDA scales pods; Karpenter provisions GPU nodes
- **Storage:** S3 model artifacts (canonical) + EFS shared cache at pod runtime
- **Ingress:** ALB with HTTPS, 300s idle timeout

## Prerequisites

- AWS CLI, Terraform >= 1.5, kubectl, Helm >= 3
- AWS account with `g5.4xlarge` quota in target region
- ACM certificate for your inference hostname
- HuggingFace token (optional, for gated models)

## Repository Layout

```
terraform/
  bootstrap/          # S3 + DynamoDB for remote state (run once)
  modules/            # vpc, eks, efs, ecr, s3-models, karpenter, alb-controller
  environments/
    dev/              # Dev stack (branch: dev)
    prod/             # Production stack (branch: main)
kubernetes/
  karpenter/          # EC2NodeClass + On-Demand/Spot NodePools
  gpu/                # NVIDIA device plugin
  vllm/               # Deployment, ingress, KEDA, EFS PVC
  monitoring/         # ServiceMonitor, CloudWatch agent, alerts, dashboard
docker/
  Dockerfile.vllm     # Pinned vLLM image
scripts/
  patch-manifests.sh   # Inject Terraform outputs into manifests
  install-controllers.sh # ALB Controller (optional on dev) + Karpenter
  install-alb-controller.sh # ALB Controller only (Step 8)
  apply-ingress.sh     # HTTPS ALB Ingress (Step 8)
  install-addons.sh    # Helm add-ons (EFS CSI; optional Prometheus on dev)
  apply-monitoring.sh  # ServiceMonitor + PrometheusRules (Step 6)
  apply-keda.sh        # KEDA ScaledObject (Step 7)
  deploy-k8s.sh        # Patch + kubectl apply
  fix-gpu-scheduling.sh # Clear stale GPU NodeClaims/nodes, re-apply vLLM
  delete-k8s.sh        # Remove K8s workloads
  delete-addons.sh     # Uninstall Helm add-ons
  destroy.sh           # Full teardown (K8s → Helm → terraform destroy)
  lib/                 # Shared env/cluster helpers
```

## Quick Start

Run all `make` commands from the **repository root** (`eks-vllm/`), not from `terraform/environments/*`.

| Command | Description |
|---|---|
| `make apply TF_ENVIRONMENT=prod` | Deploy AWS infrastructure |
| `make deploy-k8s TF_ENVIRONMENT=prod` | Apply Kubernetes manifests |
| `make fix-gpu TF_ENVIRONMENT=dev` | Clear stale GPU NodeClaims/nodes, re-apply vLLM |
| `make install-prometheus TF_ENVIRONMENT=dev` | Step 6: slim Prometheus + vLLM metrics (after vLLM is Running) |
| `make install-keda TF_ENVIRONMENT=dev` | Step 7: KEDA + ScaledObject (requires Step 6; also installs Prometheus) |
| `make install-alb TF_ENVIRONMENT=dev` | Step 8: ALB Controller + Ingress (HTTP: `DEV_ALB_HTTP_ONLY=1`; HTTPS: ACM cert + hostname) |
| `AUTO_APPROVE=1 make delete-k8s TF_ENVIRONMENT=prod` | Remove K8s workloads (keeps cluster) |
| `AUTO_APPROVE=1 make destroy TF_ENVIRONMENT=prod` | Delete everything for an environment |

Set `TF_ENVIRONMENT=dev` or `TF_ENVIRONMENT=prod` (default: `prod`).

Scripts can also be run directly:

```bash
TF_ENVIRONMENT=dev ./scripts/deploy-k8s.sh
```

## GitHub Actions Deploy

| Branch | Environment | Cluster | Terraform path |
|---|---|---|---|
| `dev` | dev | `qwen-vllm-dev` | `terraform/environments/dev` |
| `main` | prod | `qwen-vllm-prod` | `terraform/environments/prod` |

Push to `dev` or `main` to deploy automatically. You can also run **Actions → Deploy → Run workflow** and pick the environment.

Create GitHub **Environments** named `dev` and `prod` (Settings → Environments) so each can have its own `ACM_CERTIFICATE_ARN` and `INFERENCE_HOSTNAME`.

### Required repository secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user for Terraform + EKS + ECR |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `HF_TOKEN` | HuggingFace token (synced to Secrets Manager) |

### Repository variables

| Variable | Default | Purpose |
|---|---|---|
| `INSTANCE_TYPE` | `g5.4xlarge` | GPU instance type for Karpenter node pools |
| `MODEL_NAME` | `Qwen/Qwen3-8B` (prod) / `Qwen/Qwen2.5-7B-Instruct` (dev) | HuggingFace model ID (weights + vLLM serve path) |
| `DEV_ENABLE_PROMETHEUS` | *(unset)* | Set to `1` on **dev** to enable Step 6 (slim Prometheus + ServiceMonitor) |
| `DEV_ENABLE_GRAFANA` | *(unset)* | Set to `1` on **dev** to enable Grafana in slim Prometheus stack (requires Step 6) |
| `DEV_ENABLE_KEDA` | *(unset)* | Set to `1` on **dev** to enable Step 7 (KEDA + ScaledObject; also enables Prometheus) |
| `DEV_ENABLE_ALB` | *(unset)* | Set to `1` on **dev** to enable Step 8 (ALB Controller + Ingress) |
| `DEV_ALB_HTTP_ONLY` | *(unset)* | Set to `1` on **dev** for HTTP-only ALB on port 80 (no ACM / hostname; use ALB DNS) |

Dev uses 1 Karpenter replica (single system node); prod uses 2.

Set repo-wide or **per-environment** variables under **Settings → Secrets and variables → Actions** (prefer **dev** / **prod** environments for `INSTANCE_TYPE`, `MODEL_NAME`, `DEV_ENABLE_*`).

Optional **Helm chart overrides** (unset = defaults in `scripts/lib/chart-versions.sh`):

| Variable | Default | Chart |
|---|---|---|
| `KARPENTER_CHART_VERSION` | `1.0.8` | Karpenter |
| `ALB_CHART_VERSION` | `1.8.2` | AWS Load Balancer Controller |
| `AWS_EFS_CSI_CHART_VERSION` | `3.1.7` | AWS EFS CSI Driver |
| `KUBE_PROMETHEUS_STACK_CHART_VERSION` | `86.2.3` | kube-prometheus-stack |
| `KEDA_CHART_VERSION` | `2.16.1` | KEDA |
| `EXTERNAL_SECRETS_CHART_VERSION` | `2.6.0` | External Secrets Operator |
| `NVIDIA_DEVICE_PLUGIN_VERSION` | `0.14.5` | NVIDIA device plugin (manifest, not Helm) |

Bump versions in **`scripts/lib/chart-versions.sh`** (single source of truth), then re-run `install-controllers` + `install-addons`.

### Per-environment secrets (dev / prod environments)

| Secret | Purpose |
|---|---|
| `ACM_CERTIFICATE_ARN` | ACM cert ARN for HTTPS ingress (not needed when `DEV_ALB_HTTP_ONLY=1`) |
| `INFERENCE_HOSTNAME` | Public hostname for HTTPS (e.g. `dev.inference.example.com`; not needed for HTTP-only) |

HF tokens are stored per environment:
- **prod:** `qwen-vllm/hf-token`
- **dev:** `qwen-vllm-dev/hf-token`

The IAM user needs permissions for Terraform (VPC, EKS, EFS, ECR, IAM, etc.), ECR push, Secrets Manager, and `eks:DescribeCluster`.

### What the deploy workflow does

1. `terraform apply` in `terraform/environments/<env>` (AWS + IAM only)
2. Install Karpenter (+ ALB Controller when `DEV_ENABLE_ALB=1` or prod) via `install-controllers.sh`
3. Install Helm add-ons: **dev** — EFS CSI only (optional Prometheus/KEDA when `DEV_ENABLE_*=1`); **prod** — full stack
4. Sync `HF_TOKEN` → AWS Secrets Manager (prod only)
5. Build and push vLLM image to ECR
6. Patch and apply Kubernetes manifests (monitoring / KEDA / Ingress when respective `DEV_ENABLE_*=1`)

Pull requests targeting `dev` or `main` that touch `terraform/**` run `terraform plan` for the matching environment.

### Policy gates (P0 / P1)

Workflow **`.github/workflows/policy.yml`** runs on every PR and push to `dev` / `main`:

| Job | Tool | What it checks |
|-----|------|----------------|
| `terraform-fmt-validate` | Terraform 1.15.6 | `fmt -check` + `validate` (all modules/envs, `-backend=false`) |
| `tflint` | tflint + AWS ruleset | Lint under `terraform/` (`terraform/.tflint.hcl`) |
| `checkov` | Checkov | Terraform security (`/.checkov.yml`, documented skips) |
| `secret-scan` | gitleaks | Leaked secrets in git history |

**Branch protection (recommended):** require all four jobs before merge.

**Local:**

```bash
  # P0 only (Terraform only)
  terraform fmt -check -recursive terraform/
  # full P0+P1 (install tflint + checkov first, e.g. brew install tflint && pipx install checkov)
  make lint-terraform
  # checkov only (environments + modules via composition; excludes bootstrap)
  checkov -d terraform/environments --config-file .checkov.yml
```

P2+ (kubeconform, conftest, image scan) not included yet.

### Reset (manual recovery)

**Actions → Reset → Run workflow** — recovery when the cluster exists but vLLM is stuck, or Terraform state is locked.

| Action | Use when |
|--------|----------|
| `fix-gpu` | Pending GPU pods, stale NodeClaims |
| `redeploy-k8s` | Re-apply manifests only |
| `reset-k8s` | Delete + redeploy K8s workloads |
| `force-unlock` | Stale Terraform lock after crashed Deploy (paste **lock_id** from error) |

| Action | Local equivalent | What it does |
|---|---|---|
| `fix-gpu` | `make fix-gpu` | Delete stale NodeClaims + GPU nodes, re-apply vLLM (keeps PVC/model cache) |
| `redeploy-k8s` | `make deploy-k8s` | Patch manifests from Terraform outputs and `kubectl apply` |
| `reset-k8s` | `AUTO_APPROVE=1 make delete-k8s` then `make deploy-k8s` | Remove vLLM/Karpenter workloads, then redeploy |
| `force-unlock` | `LOCK_ID=<uuid> make force-unlock-terraform` | Release stale DynamoDB Terraform lock; then re-run Deploy |

Uses the same concurrency group as **Deploy** (only one run per environment at a time). Prefer **`fix-gpu` on dev** first; use **`reset-k8s`** only when workloads are badly corrupted (deletes the model PVC). Add required reviewers on the **prod** GitHub Environment before allowing `reset-k8s` there.

### Dev Step 6 — Prometheus (optional)

Enable **after** vLLM curl / CI smoke test pass (Steps 4–5). Default dev deploy skips Prometheus to keep the system node light.

**GitHub:** set environment variable `DEV_ENABLE_PROMETHEUS=1` on the **dev** environment, then push or re-run Deploy.

**Local:**

```bash
make install-prometheus TF_ENVIRONMENT=dev
```

This installs a **slim** `kube-prometheus-stack` (no Alertmanager/node-exporter by default; Grafana when `DEV_ENABLE_GRAFANA=1`) and applies ServiceMonitor + alert rules for vLLM.

Verify:

```bash
kubectl get pods -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# PromQL: vllm:gpu_cache_usage_perc{namespace="vllm"}
```

To disable again, unset `DEV_ENABLE_PROMETHEUS` and run `AUTO_APPROVE=1 make delete-addons TF_ENVIRONMENT=dev` (removes Prometheus Helm release).

### Dev Step 7 — KEDA (optional)

Enable **after** Step 6 (Prometheus scraping vLLM metrics). `DEV_ENABLE_KEDA=1` also turns on Prometheus on dev.

**GitHub:** set `DEV_ENABLE_KEDA=1` on the **dev** environment (or repository), then push or re-run Deploy.

**Local:**

```bash
make install-keda TF_ENVIRONMENT=dev
```

Verify:

```bash
kubectl get pods -n keda
kubectl get scaledobject -n vllm
kubectl describe scaledobject vllm-qwen -n vllm
kubectl get hpa -n vllm
```

KEDA scale-out triggers (any fires → scale up):

| Signal | PromQL | Dev threshold | Prod threshold |
|--------|--------|---------------|----------------|
| Waiting queue / queue depth (primary) | `vllm:queue_depth:sum` | > 2 | > 3 |
| GPU KV cache pressure | `max(vllm:gpu_cache_usage_perc{namespace="vllm"})` | > 0.80 | > 0.80 |
| TTFT p95 (tertiary) | `vllm:ttft:p95` | > 2s | > 2s |

`tokens/sec` is used in Grafana and saturation alerts only — not as a KEDA trigger. Tune thresholds in `scripts/patch-manifests.sh` after load testing.

If the cluster still shows old triggers (`num_requests_running`), re-apply:

```bash
make install-keda TF_ENVIRONMENT=dev
kubectl get scaledobject vllm-qwen -n vllm -o yaml | grep -A2 'query:'
# expect: vllm:queue_depth:sum, max(gpu_cache...), vllm:ttft:p95
```

### Dev Step 8 — ALB Ingress (optional)

Enable **after** vLLM is Running (Steps 4–5).

**Option A — HTTP only (dev, no ACM):** set `DEV_ENABLE_ALB=1` and `DEV_ALB_HTTP_ONLY=1`, then push or re-run Deploy.

**Option B — HTTPS:** set `DEV_ENABLE_ALB=1` plus dev environment secrets `ACM_CERTIFICATE_ARN` and `INFERENCE_HOSTNAME`.

**GitHub:** set the variables above, then push or re-run Deploy.

**Local (HTTP):**

```bash
DEV_ALB_HTTP_ONLY=1 make install-alb TF_ENVIRONMENT=dev
```

**Local (HTTPS):**

```bash
ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:ACCOUNT:certificate/UUID \
INFERENCE_HOSTNAME=dev.inference.example.com \
make install-alb TF_ENVIRONMENT=dev
```

Verify:

```bash
kubectl get ingress vllm-qwen -n vllm
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# After ADDRESS appears (may take 2–5 min):
# HTTP (use ALB hostname from ingress status):
curl http://$(kubectl get ingress vllm-qwen -n vllm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/v1/models

# HTTPS (custom hostname):
curl https://dev.inference.example.com/v1/models
```

### Local teardown

Run from the repository root:

**In-cluster reset (keeps EKS + Terraform; preferred over destroy)**

| Tier | Command | When to use |
|---|---|---|
| Light | `make fix-gpu TF_ENVIRONMENT=dev` | Pod Pending/Evicted, `karpenter.sh/disrupted`, NodeClaim quota stuck |
| Medium | `make deploy-k8s TF_ENVIRONMENT=dev` | Re-apply manifests after config changes (also clears stale NodeClaims) |
| Heavy | `AUTO_APPROVE=1 make delete-k8s TF_ENVIRONMENT=dev && make deploy-k8s TF_ENVIRONMENT=dev` | vLLM namespace corrupted; deletes PVC (model may re-download) |

Remove workloads only (keeps EKS cluster and Terraform infrastructure):

```bash
AUTO_APPROVE=1 make delete-k8s TF_ENVIRONMENT=dev    # or prod
```

Uninstall Helm add-ons (EFS CSI, External Secrets, KEDA, Prometheus):

```bash
AUTO_APPROVE=1 make delete-addons TF_ENVIRONMENT=dev
```

Destroy everything for an environment (Kubernetes → Helm → `terraform destroy`):

```bash
AUTO_APPROVE=1 make destroy TF_ENVIRONMENT=dev
```

**Preserved by destroy:**
- Terraform **bootstrap** state bucket (`prevent_destroy`)
- **Model-artifacts S3 bucket** and all uploaded weights — `module.s3_models` is removed from Terraform state before destroy so objects are kept

**GPU cleanup:** destroy deletes NodeClaims/NodePools, force-removes GPU nodes from Kubernetes, and terminates any remaining G5 EC2 instances (EC2 API fallback if Karpenter is stuck).

After destroy, before re-deploying the same environment:

```bash
make import-s3-models TF_ENVIRONMENT=dev   # re-attach existing model bucket to Terraform
make apply TF_ENVIRONMENT=dev
```

Each command prompts for confirmation by typing the environment name (`dev` or `prod`) unless `AUTO_APPROVE=1` is set.

If an environment was **never deployed**, delete/destroy exits cleanly after reporting `Cluster: qwen-vllm-dev (not deployed)` — no error.

### Environment sizing

| | dev | prod |
|---|---|---|
| Cluster | `qwen-vllm-dev` | `qwen-vllm-prod` |
| VPC CIDR | `10.1.0.0/16` | `10.0.0.0/16` |
| NAT gateways | 1 (single) | 2 (HA) |
| System nodes | 1× `m6i.large` | 2× `m6i.large` |
| vLLM replicas | 1 | 2 |
| GPU instance (default) | `g5.2xlarge` (8 vCPU quota) | `g5.4xlarge` |
| HF secret | `qwen-vllm-dev/hf-token` | `qwen-vllm/hf-token` |
| Terraform state key | `dev/terraform.tfstate` | `prod/terraform.tfstate` |

### One-time bootstrap (still manual)

Remote Terraform state must exist before the first GitHub deploy:

```bash
cd terraform/bootstrap
terraform init && terraform apply
```

## Rollout Sequence (local alternative)

All steps below assume you are in the repository root and use `TF_ENVIRONMENT` (`dev` or `prod`).

### 1. Bootstrap Terraform state (once per AWS account)

```bash
cd terraform/bootstrap
terraform init && terraform apply
cd ../..
```

### 2. Deploy infrastructure

```bash
make init TF_ENVIRONMENT=prod
make plan TF_ENVIRONMENT=prod
make apply TF_ENVIRONMENT=prod
```

Or manually:

```bash
cd terraform/environments/prod   # or dev
terraform init && terraform apply
```

Configure kubectl:

```bash
make kubeconfig-prod   # or: make kubeconfig-dev
```

### 3. Install controllers and add-ons

```bash
make install-controllers TF_ENVIRONMENT=prod
make install-addons TF_ENVIRONMENT=prod
```

`install-controllers` installs ALB Controller and Karpenter via Helm after the cluster is ready (avoids Terraform RBAC issues in CI). Karpenter and ALB IAM roles are still created by Terraform.

Sync the HuggingFace token to Secrets Manager:

```bash
HF_TOKEN=hf_xxx make sync-hf-secret TF_ENVIRONMENT=prod
```

### 4. Build, push, upload model, and deploy

```bash
make build-image TF_ENVIRONMENT=prod

# One-time per MODEL_NAME + MODEL_VERSION (default v1). ~15 GB for 7B.
HF_TOKEN=hf_xxx make upload-model TF_ENVIRONMENT=prod

ACM_CERTIFICATE_ARN=arn:aws:acm:... \
INFERENCE_HOSTNAME=inference.example.com \
make deploy-k8s TF_ENVIRONMENT=prod
```

`make build-image` pushes the vLLM image (`:v0.8.4`) and the S3 sync helper (`:model-downloader-v2`) to ECR.

`make upload-model` downloads from Hugging Face locally and uploads versioned weights to the Terraform-managed S3 bucket (`s3://{prefix}-model-artifacts/models/{model}/{version}/`). **If that version already exists in S3, the script exits immediately** (no HuggingFace re-download). Use `FORCE_UPLOAD=1` to overwrite. Set `MODEL_VERSION=v2` when promoting a new revision; bump the GitHub repo var `MODEL_VERSION` to match.

`deploy-k8s` verifies the S3 manifest exists, runs the **model-seed** job on a system node (S3 → EFS), then rolls out vLLM. The init container re-syncs only when the version changes.

Patched manifests are written to `kubernetes/.generated/<env>/`.

<details>
<summary>Manual add-on and manifest steps (if not using scripts)</summary>

Use the same pinned versions as `scripts/lib/chart-versions.sh` (defaults shown below).

**EFS CSI driver** (uses IRSA role from Terraform):

```bash
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --version 3.1.7 \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw efs_csi_role_arn)
```

**External Secrets Operator** (for HF token from Secrets Manager):

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version 2.6.0
```

Store HF token in Secrets Manager (`qwen-vllm/hf-token` for prod, `qwen-vllm-dev/hf-token` for dev), then apply:

```bash
kubectl apply -f kubernetes/vllm/cluster-secret-store.yaml
kubectl apply -f kubernetes/vllm/external-secret-hf.yaml
```

**KEDA:**

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version 2.16.1
```

**Prometheus** (for metrics + KEDA triggers):

```bash
helm upgrade --install kube-prometheus-stack \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 86.2.3
```

**Karpenter / ALB Controller** — see `scripts/install-controllers.sh` (Karpenter `1.0.8`, ALB `1.8.2`).

Patch and apply manifests manually:

```bash
make patch TF_ENVIRONMENT=prod
# Patched files in kubernetes/.generated/prod/
```

Placeholders replaced by `patch-manifests.sh`:
- `CLUSTER_NAME`, `KARPENTER_NODE_ROLE_NAME`, `INSTANCE_PROFILE`
- `FILE_SYSTEM_ID`, `ACCESS_POINT_ID`, `ECR_REPOSITORY_URL`
- `ACM_CERTIFICATE_ARN`, `CLOUDWATCH_AGENT_ROLE_ARN`, `INFERENCE_HOSTNAME`
- `__MODEL_ID_VALUE__`, `__MODEL_PATH_VALUE__`, `__MODEL_VERSION_VALUE__`, `__MODEL_S3_BUCKET__`, `__VLLM_MODEL_S3_ROLE_ARN__`, `__VLLM_REPLICAS__`, `INSTANCE_FAMILY`, `INSTANCE_SIZE` (from `MODEL_NAME`, `MODEL_VERSION`, `INSTANCE_TYPE`; dev uses 1 vLLM replica, prod uses 2)

</details>

### 5. Validate

```bash
# Wait for GPU nodes (Karpenter provisions after vLLM pods are Pending)
kubectl get nodes -l workload=gpu
kubectl get pods -n vllm -w
```

**Troubleshooting**

| Symptom | Cause | Fix |
|---|---|---|
| Deploy fails: model not found in S3 | Weights not uploaded for `MODEL_VERSION` | `make upload-model TF_ENVIRONMENT=dev` (set `MODEL_VERSION` if not `v1`) |
| `model-seed` fails / S3 access denied | IRSA not applied or wrong bucket | `terraform apply`, redeploy; check SA annotation: `kubectl get sa vllm -n vllm -o yaml` |
| `model-seed` Pending, `Insufficient cpu` | System node out of CPU | Scale system node group or temporarily reduce addon CPU; check `kubectl describe pod -n vllm -l job-name=model-seed` |
| `ImagePullBackOff` on model-downloader | ECR image missing | `make build-image TF_ENVIRONMENT=dev` (pushes `:model-downloader-v2`), redeploy |
| No GPU nodes | Karpenter only adds GPU nodes when pods request `nvidia.com/gpu` | Wait for model-seed to complete, then vLLM deployment |
| `VcpuLimitExceeded` / GPU node won't launch | Default G/VT vCPU quota is often 8; `g5.4xlarge` needs 16 | Dev defaults to `g5.2xlarge`. For prod, request quota increase: [AWS EC2 quota request](https://console.aws.amazon.com/servicequotas/) → **Running On-Demand G and VT instances** → at least 32 |
| Pod Pending, `karpenter.sh/disrupted`, many NodeClaims | Stale GPU node/NodeClaim after evicted rollout | `make fix-gpu TF_ENVIRONMENT=dev` or **Actions → Reset → fix-gpu** |
| `no such host` on kubectl | Stale kubeconfig after cluster recreate | `make kubeconfig-dev` or `aws eks update-kubeconfig --region us-east-1 --name qwen-vllm-dev` |
| Wrong cluster / stale kubeconfig | Context points at destroyed env | `make kubeconfig-dev` or `make kubeconfig-prod` from repo root |
| `Error acquiring the state lock` / `ConditionalCheckFailedException` | Stale or concurrent Terraform lock | Wait for Deploy to finish. If stale: **Actions → Reset → force-unlock** (paste lock ID) or `LOCK_ID=<uuid> TF_ENVIRONMENT=dev make force-unlock-terraform`, then re-run Deploy |

```bash
# Port-forward for local test (dev model path)
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000

curl http://localhost:8000/v1/models

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models/Qwen2.5-7B-Instruct/v1",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 64
  }'
```

### 6. Load test and verify autoscaling

- Confirm KEDA scales replicas when **waiting queue** or **max GPU cache** exceeds thresholds (see Step 7 table)
- Watch recording rules: `vllm:ttft:p95`, `vllm:generation_tps:sum` in Prometheus
- Alerts: `VLLMThroughputSaturation` (queue + high tokens/sec), `VLLMThroughputStall` (queue + zero tokens/sec)
- Confirm Karpenter launches Spot G5 nodes when pending GPU pods exist
- Import Grafana dashboard from `kubernetes/monitoring/grafana-dashboard-vllm.json`

### 7. Production HA baseline

Prod defaults (see **`docs/production-ha-slo.md`**):

| Control | Prod value |
|---------|------------|
| PDB | `minAvailable: 1` (use `2` when running 3+ replicas) |
| Rolling update | `maxSurge: 1`, `maxUnavailable: 0` |
| Probes | `startupProbe` + `readinessProbe` + `livenessProbe` on `/health` |
| Graceful shutdown | `preStop` sleep 30s + `terminationGracePeriodSeconds: 120` |
| Spot | On-Demand weight 100, Spot weight 10; Karpenter interruption queue + EFS cache |

**SLO targets:** TTFT p95 < 2s · e2e p95 < 10s · error rate < 1% · availability ≥ 99.5%  
Prometheus alerts: `VLLMSLO*` in `kubernetes/monitoring/prometheus-rules.yaml`

**Load test:**

```bash
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000 &
make load-test-slo TF_ENVIRONMENT=prod
```

## vLLM Configuration

| Parameter | Value |
|---|---|
| Model | Qwen/Qwen3-8B |
| dtype | bfloat16 |
| max-model-len | 8192 |
| gpu-memory-utilization | 0.90 |
| prefix caching | enabled |

## Autoscaling

| Layer | Tool | Trigger |
|---|---|---|
| Pods | KEDA | waiting queue, max GPU cache, TTFT p95 (see `keda-scaledobject.yaml`) |
| Nodes | Karpenter | Pending pods requesting `nvidia.com/gpu` |

Optional ALB fallback scaler: `kubernetes/vllm/keda-scaledobject-alb-fallback.yaml` (apply instead of primary KEDA config).

## Cost Estimate (us-east-1)

| Component | ~Monthly |
|---|---|
| EKS control plane | $73 |
| 2× g5.4xlarge On-Demand | $2,350 |
| 2× Spot burst (50% duty) | $580 |
| EFS + NAT + ALB | $150 |
| **Total** | **~$3,150** |

## Key Risks

- **Spot interruption:** min 2 On-Demand replicas + preStop drain + 120s termination grace; Spot burst only
- **Cold start:** EFS model cache + startupProbe; readiness on `/health` after model load
- **GPU quota:** request `g5.4xlarge` increase before deploy
- **ALB timeout:** 300s idle timeout configured; match client timeouts

## CI

- **Deploy:** `.github/workflows/deploy.yml` — `dev` branch → dev, `main` branch → prod
- **Plan:** `.github/workflows/terraform-plan.yml` — `terraform plan` on PRs to `dev` or `main`
- Pin vLLM image tag in ECR; scan on push enabled
