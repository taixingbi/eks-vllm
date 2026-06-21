#!/usr/bin/env bash
# Install or upgrade cluster Helm add-ons (idempotent).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/helm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXTERNAL_SECRETS_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-2.6.0}"
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.16.1}"
KUBE_PROMETHEUS_STACK_CHART_VERSION="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-86.2.3}"
AWS_EFS_CSI_CHART_VERSION="${AWS_EFS_CSI_CHART_VERSION:-3.1.7}"

cd "$TF_DIR"
EFS_CSI_ROLE_ARN=$(terraform output -raw efs_csi_role_arn)

helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ 2>/dev/null || true
helm repo update

helm_upgrade_install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --version "${AWS_EFS_CSI_CHART_VERSION}" \
  --set controller.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${EFS_CSI_ROLE_ARN}" \
  --wait --timeout 10m

if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  echo "Skipping External Secrets, KEDA, and Prometheus on dev (minimal path)"
  echo "Cluster add-ons installed (${TF_ENVIRONMENT})."
  exit 0
fi

EXTERNAL_SECRETS_ROLE_ARN=$(terraform output -raw external_secrets_role_arn)

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update

helm_upgrade_install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${EXTERNAL_SECRETS_ROLE_ARN}" \
  --wait --timeout 10m

helm_upgrade_install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version "${KEDA_CHART_VERSION}" \
  --wait --timeout 10m

PROM_HELM_ARGS=(
  --namespace monitoring --create-namespace
  --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
  --wait --timeout 15m
)

# OCI avoids GitHub release asset 500s from prometheus-community Helm repo.
helm_upgrade_install kube-prometheus-stack \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  "${PROM_HELM_ARGS[@]}"

echo "Cluster add-ons installed (${TF_ENVIRONMENT})."
