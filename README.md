# Qwen 8B + vLLM on EKS (G5)

Production-ready Terraform and Kubernetes manifests for serving **Qwen3-8B** via vLLM on AWS EKS with G5 GPU nodes, Karpenter autoscaling, ALB ingress, EFS model cache, and KEDA-driven replica scaling.

## Architecture

- **Baseline:** 2× On-Demand `g5.4xlarge` (1 vLLM replica per GPU, spread across AZs)
- **Burst:** Karpenter Spot `g5.4xlarge` pool (up to ~8 nodes)
- **Scaling:** KEDA scales pods; Karpenter provisions GPU nodes
- **Storage:** EFS shared model cache (~16 GB weights)
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
  modules/            # vpc, eks, efs, ecr, karpenter, alb-controller
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
| `MODEL_NAME` | `Qwen/Qwen3-8B` | HuggingFace model ID (weights + vLLM serve path) |
| `DEV_ENABLE_PROMETHEUS` | *(unset)* | Set to `1` on **dev** to enable Step 6 (slim Prometheus + ServiceMonitor) |
| `DEV_ENABLE_KEDA` | *(unset)* | Set to `1` on **dev** to enable Step 7 (KEDA + ScaledObject; also enables Prometheus) |
| `DEV_ENABLE_ALB` | *(unset)* | Set to `1` on **dev** to enable Step 8 (ALB Controller + Ingress) |
| `DEV_ALB_HTTP_ONLY` | *(unset)* | Set to `1` on **dev** for HTTP-only ALB on port 80 (no ACM / hostname; use ALB DNS) |

Dev uses 1 Karpenter replica (single system node); prod uses 2.

Set repo-wide or **per-environment** variables under **Settings → Secrets and variables → Actions** (prefer **dev** / **prod** environments for `INSTANCE_TYPE`, `MODEL_NAME`, `DEV_ENABLE_*`).

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

### Reset (manual recovery)

**Actions → Reset → Run workflow** — does **not** run Terraform or Helm. Use when the cluster exists but vLLM is stuck (Pending GPU pods, evicted rollouts, stale NodeClaims).

| Action | Local equivalent | What it does |
|---|---|---|
| `fix-gpu` | `make fix-gpu` | Delete stale NodeClaims + GPU nodes, re-apply vLLM (keeps PVC/model cache) |
| `redeploy-k8s` | `make deploy-k8s` | Patch manifests from Terraform outputs and `kubectl apply` |
| `reset-k8s` | `AUTO_APPROVE=1 make delete-k8s` then `make deploy-k8s` | Remove vLLM/Karpenter workloads, then redeploy |

Uses the same concurrency group as **Deploy** (only one run per environment at a time). Prefer **`fix-gpu` on dev** first; use **`reset-k8s`** only when workloads are badly corrupted (deletes the model PVC). Add required reviewers on the **prod** GitHub Environment before allowing `reset-k8s` there.

### Dev Step 6 — Prometheus (optional)

Enable **after** vLLM curl / CI smoke test pass (Steps 4–5). Default dev deploy skips Prometheus to keep the system node light.

**GitHub:** set environment variable `DEV_ENABLE_PROMETHEUS=1` on the **dev** environment, then push or re-run Deploy.

**Local:**

```bash
make install-prometheus TF_ENVIRONMENT=dev
```

This installs a **slim** `kube-prometheus-stack` (no Grafana/Alertmanager/node-exporter) and applies ServiceMonitor + alert rules for vLLM.

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

Each command prompts for confirmation by typing the environment name (`dev` or `prod`) unless `AUTO_APPROVE=1` is set.

If an environment was **never deployed**, delete/destroy exits cleanly after reporting `Cluster: qwen-vllm-dev (not deployed)` — no error.

Bootstrap state (`terraform/bootstrap`) is not removed by `destroy` — the S3 bucket has `prevent_destroy` enabled.

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

### 4. Build, push, and deploy

```bash
make build-image TF_ENVIRONMENT=prod

ACM_CERTIFICATE_ARN=arn:aws:acm:... \
INFERENCE_HOSTNAME=inference.example.com \
make deploy-k8s TF_ENVIRONMENT=prod
```

`make build-image` pushes the vLLM image (`:v0.8.4`) and a lightweight model downloader (`:model-downloader`) to ECR. Both are used by the deployment init container; prod also uses the downloader for the model-seed job.

`deploy-k8s` patches manifests from Terraform outputs, applies them in order, and waits for the model-seed job on prod (skipped on dev). Ingress is applied when `DEV_ALB_HTTP_ONLY=1` (HTTP) or when `ACM_CERTIFICATE_ARN` is set (HTTPS); otherwise skipped on dev.

Patched manifests are written to `kubernetes/.generated/<env>/`.

<details>
<summary>Manual add-on and manifest steps (if not using scripts)</summary>

**EFS CSI driver** (uses IRSA role from Terraform):

```bash
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw efs_csi_role_arn)
```

**External Secrets Operator** (for HF token from Secrets Manager):

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace
```

Store HF token in Secrets Manager (`qwen-vllm/hf-token` for prod, `qwen-vllm-dev/hf-token` for dev), then apply:

```bash
kubectl apply -f kubernetes/vllm/cluster-secret-store.yaml
kubectl apply -f kubernetes/vllm/external-secret-hf.yaml
```

**KEDA:**

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

**Prometheus** (for metrics + KEDA triggers):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

Patch and apply manifests manually:

```bash
make patch TF_ENVIRONMENT=prod
# Patched files in kubernetes/.generated/prod/
```

Placeholders replaced by `patch-manifests.sh`:
- `CLUSTER_NAME`, `KARPENTER_NODE_ROLE_NAME`, `INSTANCE_PROFILE`
- `FILE_SYSTEM_ID`, `ACCESS_POINT_ID`, `ECR_REPOSITORY_URL`
- `ACM_CERTIFICATE_ARN`, `CLOUDWATCH_AGENT_ROLE_ARN`, `INFERENCE_HOSTNAME`
- `__MODEL_ID_VALUE__`, `__MODEL_PATH_VALUE__`, `__VLLM_REPLICAS__`, `INSTANCE_FAMILY`, `INSTANCE_SIZE` (from `MODEL_NAME` / `INSTANCE_TYPE` env vars; dev uses 1 vLLM replica, prod uses 2)

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
| `model-seed` Pending, `Insufficient cpu` | Dev has one `m6i.large`; Karpenter + Prometheus consume most CPU | On **dev**, model-seed is skipped — delete the stuck job and redeploy: `kubectl delete job model-seed -n vllm && make deploy-k8s TF_ENVIRONMENT=dev`. vLLM downloads via init container on the GPU node. |
| `ImagePullBackOff` on `huggingface/huggingface_hub` | That Docker Hub image does not exist | Run `make build-image TF_ENVIRONMENT=dev` (pushes `:model-downloader` to ECR), delete the job, redeploy |
| No GPU nodes | Karpenter only adds GPU nodes when pods request `nvidia.com/gpu` | Wait for vLLM deployment after model-seed completes (prod) or after deploy applies vLLM (dev) |
| `VcpuLimitExceeded` / GPU node won't launch | Default G/VT vCPU quota is often 8; `g5.4xlarge` needs 16 | Dev defaults to `g5.2xlarge`. For prod, request quota increase: [AWS EC2 quota request](https://console.aws.amazon.com/servicequotas/) → **Running On-Demand G and VT instances** → at least 32 |
| Pod Pending, `karpenter.sh/disrupted`, many NodeClaims | Stale GPU node/NodeClaim after evicted rollout | `make fix-gpu TF_ENVIRONMENT=dev` or **Actions → Reset → fix-gpu** |
| `no such host` on kubectl | Stale kubeconfig after cluster recreate | `make kubeconfig-dev` or `aws eks update-kubeconfig --region us-east-1 --name qwen-vllm-dev` |
| Wrong cluster / stale kubeconfig | Context points at destroyed env | `make kubeconfig-dev` or `make kubeconfig-prod` from repo root |

```bash
# Port-forward for local test (dev model path)
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000

curl http://localhost:8000/v1/models

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 64
  }'
```

### 6. Load test and verify autoscaling

- Confirm KEDA scales replicas when GPU cache > 80% or queue depth > 5
- Confirm Karpenter launches Spot G5 nodes when pending GPU pods exist
- Import Grafana dashboard from `kubernetes/monitoring/grafana-dashboard-vllm.json`

### 7. Production HA baseline

Ensure 2 On-Demand replicas across AZs (default in deployment). Update PDB to `minAvailable: 2` when running 3+ replicas.

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
| Pods | KEDA | `vllm:gpu_cache_usage_perc` > 80%, `vllm:num_requests_running` > 5 |
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

- **Spot interruption:** min 2 On-Demand replicas + 120s termination grace period
- **Cold start:** EFS model cache + model-seed Job; pod startup probe allows 5 min
- **GPU quota:** request `g5.4xlarge` increase before deploy
- **ALB timeout:** 300s idle timeout configured; match client timeouts

## CI

- **Deploy:** `.github/workflows/deploy.yml` — `dev` branch → dev, `main` branch → prod
- **Plan:** `.github/workflows/terraform-plan.yml` — `terraform plan` on PRs to `dev` or `main`
- Pin vLLM image tag in ECR; scan on push enabled
