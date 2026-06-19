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
  environments/prod/  # Production stack
kubernetes/
  karpenter/          # EC2NodeClass + On-Demand/Spot NodePools
  gpu/                # NVIDIA device plugin
  vllm/               # Deployment, ingress, KEDA, EFS PVC
  monitoring/         # ServiceMonitor, CloudWatch agent, alerts, dashboard
docker/
  Dockerfile.vllm     # Pinned vLLM image
scripts/
  patch-manifests.sh  # Inject Terraform outputs into manifests
```

## Rollout Sequence

### 1. Bootstrap Terraform state

```bash
cd terraform/bootstrap
terraform init && terraform apply
```

### 2. Deploy infrastructure

```bash
cd terraform/environments/prod
terraform init
terraform plan
terraform apply
```

Configure kubectl:

```bash
aws eks update-kubeconfig --region us-east-1 --name qwen-vllm-prod
```

### 3. Install cluster add-ons

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

Store HF token in Secrets Manager as `qwen-vllm/hf-token`, then apply:

```bash
kubectl apply -f kubernetes/vllm/cluster-secret-store.yaml
kubectl apply -f kubernetes/vllm/external-secret-hf.yaml
```

**KEDA:**

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

**Prometheus (for metrics + KEDA triggers):**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

Karpenter and ALB Controller are installed by Terraform Helm releases.

### 4. Patch and apply Kubernetes manifests

```bash
chmod +x scripts/patch-manifests.sh
./scripts/patch-manifests.sh
# Follow printed kubectl apply commands
```

Or manually replace placeholders in manifests:
- `CLUSTER_NAME`, `KARPENTER_NODE_ROLE_NAME`, `INSTANCE_PROFILE`
- `FILE_SYSTEM_ID`, `ACCESS_POINT_ID`, `ECR_REPOSITORY_URL`
- `ACM_CERTIFICATE_ARN`, `CLOUDWATCH_AGENT_ROLE_ARN`

Apply order:

```bash
kubectl apply -f kubernetes/karpenter/        # after patching
kubectl apply -f kubernetes/gpu/
kubectl apply -f kubernetes/vllm/namespace.yaml
kubectl apply -f kubernetes/vllm/configmap.yaml
kubectl apply -f kubernetes/vllm/pvc-efs.yaml   # after patching
kubectl apply -f kubernetes/vllm/model-seed-job.yaml
kubectl wait --for=condition=complete job/model-seed -n vllm --timeout=3600s
kubectl apply -f kubernetes/vllm/deployment.yaml  # after patching
kubectl apply -f kubernetes/vllm/service.yaml
kubectl apply -f kubernetes/vllm/ingress.yaml     # set ACM cert + hostname
kubectl apply -f kubernetes/vllm/keda-scaledobject.yaml
kubectl apply -f kubernetes/monitoring/
```

### 5. Build and push vLLM image

```bash
ECR_URL=$(cd terraform/environments/prod && terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker build -t "${ECR_URL}:v0.8.4" -f docker/Dockerfile.vllm .
docker push "${ECR_URL}:v0.8.4"
```

### 6. Validate

```bash
# Wait for GPU nodes
kubectl get nodes -l workload=gpu
kubectl get pods -n vllm -w

# Port-forward for local test
kubectl port-forward -n vllm svc/vllm-qwen 8000:8000

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-8B",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 64
  }'
```

### 7. Load test and verify autoscaling

- Confirm KEDA scales replicas when GPU cache > 80% or queue depth > 5
- Confirm Karpenter launches Spot G5 nodes when pending GPU pods exist
- Import Grafana dashboard from `kubernetes/monitoring/grafana-dashboard-vllm.json`

### 8. Production HA baseline

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

## CI Recommendations

- `terraform plan` on PR for `terraform/environments/prod`
- `kubectl diff` for manifest changes after patching
- Pin vLLM image tag in ECR; scan on push enabled
