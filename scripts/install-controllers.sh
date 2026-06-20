#!/usr/bin/env bash
# Install ALB Controller and Karpenter via Helm (after Terraform creates IAM + EKS).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster.sh"
AWS_REGION="${AWS_REGION:-us-east-1}"
ALB_CHART_VERSION="${ALB_CHART_VERSION:-1.8.2}"
KARPENTER_CHART_VERSION="${KARPENTER_CHART_VERSION:-1.0.8}"

if [[ -z "${KARPENTER_REPLICAS:-}" ]]; then
  if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
    KARPENTER_REPLICAS=1
  else
    KARPENTER_REPLICAS=2
  fi
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required"
  exit 1
fi

cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
INTERRUPTION_QUEUE=$(terraform output -raw karpenter_interruption_queue_name)

configure_kubectl >/dev/null

echo "Waiting for EKS API access..."
for _ in $(seq 1 30); do
  if kubectl auth can-i create customresourcedefinitions --all-namespaces >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

echo "Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${ALB_CHART_VERSION}" \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ALB_ROLE_ARN}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --wait --timeout 10m

echo "Installing Karpenter (${KARPENTER_REPLICAS} replica(s))..."
KARPENTER_CPU_REQUEST="1"
KARPENTER_MEM_REQUEST="1Gi"
if [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
  KARPENTER_CPU_REQUEST="250m"
  KARPENTER_MEM_REQUEST="512Mi"
fi

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace kube-system \
  --version "${KARPENTER_CHART_VERSION}" \
  --set replicas="${KARPENTER_REPLICAS}" \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.clusterEndpoint="${CLUSTER_ENDPOINT}" \
  --set settings.interruptionQueue="${INTERRUPTION_QUEUE}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set controller.resources.requests.cpu="${KARPENTER_CPU_REQUEST}" \
  --set controller.resources.requests.memory="${KARPENTER_MEM_REQUEST}" \
  --set controller.resources.limits.cpu="${KARPENTER_CPU_REQUEST}" \
  --set controller.resources.limits.memory="${KARPENTER_MEM_REQUEST}" \
  --wait --timeout 10m

echo "Controllers installed (${TF_ENVIRONMENT})."
