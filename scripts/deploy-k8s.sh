#!/usr/bin/env bash
# Patch manifests and apply Kubernetes resources to the cluster.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

"${ROOT}/scripts/patch-manifests.sh"

cd "$TF_DIR"
MODEL_S3_BUCKET=$(terraform output -raw model_artifacts_bucket_name)
S3_MANIFEST="s3://${MODEL_S3_BUCKET}/${MODEL_S3_PREFIX}/.model-manifest.json"
echo "Checking model artifacts at ${S3_MANIFEST} ..."
if ! aws s3 ls "${S3_MANIFEST}" >/dev/null 2>&1; then
  echo "ERROR: Model not found in S3. Upload first:"
  echo "  make upload-model TF_ENVIRONMENT=${TF_ENVIRONMENT} MODEL_VERSION=${MODEL_VERSION}"
  exit 1
fi

if [[ "${TF_ENVIRONMENT}" != "dev" ]]; then
  TMP_SECRETS=$(mktemp)
  trap 'rm -f "$TMP_SECRETS"' EXIT
  sed "s|qwen-vllm/hf-token|${HF_SECRET_NAME}|g" \
    "${ROOT}/kubernetes/vllm/external-secret-hf.yaml" > "${TMP_SECRETS}"

  kubectl apply -f "${ROOT}/kubernetes/vllm/cluster-secret-store.yaml"
  kubectl apply -f "${TMP_SECRETS}"

  echo "Waiting for External Secrets (up to 5m)..."
  kubectl wait --for=condition=Ready clustersecretstore/aws-secrets-manager --timeout=300s 2>/dev/null || {
    echo "Warning: ClusterSecretStore not Ready — run: make install-addons TF_ENVIRONMENT=${TF_ENVIRONMENT}"
  }
  kubectl wait --for=condition=Ready externalsecret/hf-token -n vllm --timeout=300s 2>/dev/null || {
    echo "Warning: hf-token ExternalSecret not Ready — continuing (HF_TOKEN is optional for public models)"
  }
fi

kubectl apply -f "${ROOT}/kubernetes/vllm/namespace.yaml"

echo "Clearing stuck Karpenter GPU nodeclaims (prevents NodePool limit exhaustion)..."
kubectl delete nodeclaims -l karpenter.sh/nodepool=g5-ondemand --ignore-not-found --wait=false 2>/dev/null || true

kubectl apply -f "${OUT_DIR}/karpenter/ec2nodeclass-g5.yaml"
kubectl apply -f "${OUT_DIR}/karpenter/nodepool-g5-ondemand.yaml"
if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  kubectl -n vllm scale deployment vllm-qwen --replicas=1 2>/dev/null || true
  if [[ "${ENABLE_KEDA}" != "1" ]]; then
    kubectl delete scaledobject vllm-qwen -n vllm --ignore-not-found 2>/dev/null || true
  fi
fi
if [[ "${TF_ENVIRONMENT}" != "dev" ]]; then
  kubectl apply -f "${OUT_DIR}/karpenter/nodepool-g5-spot.yaml"
else
  kubectl delete nodepool g5-spot --ignore-not-found 2>/dev/null || true
fi
kubectl apply -f "${OUT_DIR}/nvidia-device-plugin.yaml"
kubectl apply -f "${OUT_DIR}/vllm/configmap.yaml"
kubectl apply -f "${OUT_DIR}/vllm/pvc-efs.yaml"

kubectl delete job/model-seed -n vllm --ignore-not-found
kubectl apply -f "${OUT_DIR}/vllm/model-seed-job.yaml"
if ! kubectl wait --for=condition=complete job/model-seed -n vllm --timeout=3600s 2>/dev/null; then
  echo "model-seed job still running or failed; check: kubectl logs -n vllm job/model-seed"
  kubectl logs -n vllm job/model-seed --tail=50 2>/dev/null || true
  exit 1
fi

kubectl apply -f "${OUT_DIR}/vllm/deployment.yaml"
kubectl -n vllm delete rs -l app=vllm-qwen --field-selector='status.replicas=0' --ignore-not-found 2>/dev/null || true
kubectl apply -f "${OUT_DIR}/vllm/service.yaml"

if [[ "${ENABLE_ALB}" == "1" ]]; then
  if [[ "${ALB_HTTP_ONLY}" == "1" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress-http.yaml"
  elif [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
    kubectl apply -f "${OUT_DIR}/vllm/ingress.yaml"
  else
    echo "Skipping ingress (set DEV_ALB_HTTP_ONLY=1 for HTTP, or ACM_CERTIFICATE_ARN for HTTPS)"
  fi
elif [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  echo "Skipping ALB ingress on dev (minimal path; use port-forward)"
  echo "Enable Step 8: DEV_ENABLE_ALB=1 + DEV_ALB_HTTP_ONLY=1, or ACM_CERTIFICATE_ARN for HTTPS"
fi

if [[ "${ENABLE_PROMETHEUS}" == "1" ]]; then
  kubectl apply -f "${OUT_DIR}/monitoring/"
elif [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  echo "Skipping monitoring on dev (minimal path)"
  echo "Enable Step 6: DEV_ENABLE_PROMETHEUS=1 make apply-monitoring TF_ENVIRONMENT=dev"
fi

if [[ "${ENABLE_KEDA}" == "1" ]]; then
  kubectl apply -f "${OUT_DIR}/vllm/keda-scaledobject.yaml"
elif [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  echo "Skipping KEDA on dev (minimal path)"
  echo "Enable Step 7: DEV_ENABLE_KEDA=1 make apply-keda TF_ENVIRONMENT=dev"
fi

echo "Kubernetes deployment complete (${TF_ENVIRONMENT})."
