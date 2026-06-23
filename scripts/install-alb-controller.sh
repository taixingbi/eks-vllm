#!/usr/bin/env bash
# Install AWS Load Balancer Controller (Step 8; requires ENABLE_ALB=1 on dev).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/helm.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ "${ENABLE_ALB}" != "1" ]]; then
  echo "ALB not enabled. Set DEV_ENABLE_ALB=1 for dev or use prod."
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required"
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)

configure_kubectl >/dev/null

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

echo "Installing AWS Load Balancer Controller..."
helm_upgrade_install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${ALB_CHART_VERSION}" \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ALB_ROLE_ARN}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --wait --timeout 10m

echo "ALB Controller installed (${TF_ENVIRONMENT})."
