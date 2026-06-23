#!/usr/bin/env bash
# Single source of truth for pinned Helm chart and add-on versions.
# Override at deploy time via env vars (e.g. GitHub Actions repository variables).
# Bump versions here in one PR; re-run install-controllers + install-addons on each env.
set -euo pipefail

export KARPENTER_CHART_VERSION="${KARPENTER_CHART_VERSION:-1.0.8}"
export ALB_CHART_VERSION="${ALB_CHART_VERSION:-1.8.2}"
export AWS_EFS_CSI_CHART_VERSION="${AWS_EFS_CSI_CHART_VERSION:-3.1.7}"
export KUBE_PROMETHEUS_STACK_CHART_VERSION="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-86.2.3}"
export KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.16.1}"
export EXTERNAL_SECRETS_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-2.6.0}"

# Not Helm — pinned manifest image (kubernetes/gpu/nvidia-device-plugin.yaml)
export NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-0.14.5}"

chart_versions_print() {
  cat <<EOF
Pinned add-on versions (${TF_ENVIRONMENT:-unknown}):
  Karpenter chart:              ${KARPENTER_CHART_VERSION}
  ALB Controller chart:         ${ALB_CHART_VERSION}
  AWS EFS CSI chart:            ${AWS_EFS_CSI_CHART_VERSION}
  kube-prometheus-stack chart:  ${KUBE_PROMETHEUS_STACK_CHART_VERSION}
  KEDA chart:                   ${KEDA_CHART_VERSION}
  External Secrets chart:       ${EXTERNAL_SECRETS_CHART_VERSION}
  NVIDIA device plugin:         v${NVIDIA_DEVICE_PLUGIN_VERSION}
EOF
}
