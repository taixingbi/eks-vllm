#!/usr/bin/env bash
# Install or upgrade cluster Helm add-ons (idempotent).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/helm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

install_prometheus() {
  local slim="${1:-false}"
  local prom_args=(
    --namespace monitoring --create-namespace
    --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
    --wait --timeout 15m
  )
  if [[ "${slim}" == "true" ]]; then
    prom_args+=(
      --set alertmanager.enabled=false
      --set kubeStateMetrics.enabled=false
      --set nodeExporter.enabled=false
      --set prometheus.prometheusSpec.resources.requests.cpu=100m
      --set prometheus.prometheusSpec.resources.requests.memory=256Mi
      --set prometheus.prometheusSpec.resources.limits.cpu=500m
      --set prometheus.prometheusSpec.resources.limits.memory=512Mi
    )
    if [[ "${ENABLE_GRAFANA}" == "1" ]]; then
      prom_args+=(--set grafana.enabled=true)
    else
      prom_args+=(--set grafana.enabled=false)
    fi
  fi

  echo "Installing kube-prometheus-stack (slim=${slim}, grafana=${ENABLE_GRAFANA:-0})..."
  helm_upgrade_install kube-prometheus-stack \
    oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    "${prom_args[@]}"
}

install_keda() {
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update
  echo "Installing KEDA..."
  helm_upgrade_install keda kedacore/keda \
    --namespace keda --create-namespace \
    --version "${KEDA_CHART_VERSION}" \
    --wait --timeout 10m
}

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
  if [[ "${ENABLE_PROMETHEUS}" == "1" ]]; then
    install_prometheus true
  fi
  if [[ "${ENABLE_KEDA}" == "1" ]]; then
    install_keda
  fi
  if [[ "${ENABLE_PROMETHEUS}" == "1" ]] || [[ "${ENABLE_KEDA}" == "1" ]]; then
    chart_versions_print
    echo "Cluster add-ons installed (${TF_ENVIRONMENT}, Prometheus=${ENABLE_PROMETHEUS}, KEDA=${ENABLE_KEDA}, Grafana=${ENABLE_GRAFANA})."
  else
    echo "Skipping External Secrets, KEDA, and Prometheus on dev (minimal path)"
    echo "Enable Step 6: DEV_ENABLE_PROMETHEUS=1 make install-addons TF_ENVIRONMENT=dev"
    echo "Enable Step 7: DEV_ENABLE_KEDA=1 make install-addons TF_ENVIRONMENT=dev (also enables Prometheus)"
  fi
  exit 0
fi

EXTERNAL_SECRETS_ROLE_ARN=$(terraform output -raw external_secrets_role_arn)

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update

helm_upgrade_install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${EXTERNAL_SECRETS_ROLE_ARN}" \
  --wait --timeout 10m

install_keda
install_prometheus false

chart_versions_print
echo "Cluster add-ons installed (${TF_ENVIRONMENT})."
