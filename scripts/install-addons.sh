#!/usr/bin/env bash
# Install or upgrade cluster Helm add-ons (idempotent).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_SECRETS_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-2.6.0}"

cd "$TF_DIR"
EFS_CSI_ROLE_ARN=$(terraform output -raw efs_csi_role_arn)

helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${EFS_CSI_ROLE_ARN}" \
  --wait --timeout 10m

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
  --wait --timeout 10m

helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --wait --timeout 10m

PROM_HELM_ARGS=(
  --namespace monitoring --create-namespace
  --wait --timeout 15m
)
if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  PROM_HELM_ARGS+=(
    --set alertmanager.enabled=false
    --set grafana.enabled=false
    --set kubeStateMetrics.enabled=false
    --set nodeExporter.enabled=false
    --set prometheus.prometheusSpec.resources.requests.cpu=100m
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi
    --set prometheus.prometheusSpec.resources.limits.cpu=500m
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi
  )
fi

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  "${PROM_HELM_ARGS[@]}"

echo "Cluster add-ons installed (${TF_ENVIRONMENT})."
