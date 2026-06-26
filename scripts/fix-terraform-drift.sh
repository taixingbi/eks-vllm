#!/usr/bin/env bash
# Reconcile Terraform state with existing AWS resources after partial apply / failed destroy.
#
# Default (import): bring orphaned AWS resources into state — preferred, no outage window.
# Delete mode: remove duplicate SG rules / KMS alias in AWS so the next apply recreates them.
#
# Usage:
#   TF_ENVIRONMENT=dev ./scripts/fix-terraform-drift.sh              # import known drift
#   TF_ENVIRONMENT=dev ./scripts/fix-terraform-drift.sh --delete     # force-delete SG rules + alias
#   TF_ENVIRONMENT=dev ./scripts/fix-terraform-drift.sh --import-only sg  # import SG rules only
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

MODE="import"
IMPORT_FILTER="all"
AWS_REGION="${AWS_REGION:-us-east-1}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --delete) MODE="delete"; shift ;;
    --import-only)
      IMPORT_FILTER="${2:?--import-only requires: sg|kms|vpc|efs|s3|eks|all}"
      shift 2
      ;;
    *) echo "Unknown argument: $1"; usage 1 ;;
  esac
done

cluster_name() {
  terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null \
    || grep -E '^cluster_name' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\([^"]*\)".*/\1/'
}

NAME_PREFIX="$(grep -E '^name_prefix' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\([^"]*\)".*/\1/')"
CLUSTER="$(cluster_name)"
KMS_ALIAS="alias/eks/${CLUSTER}"

cd "$TF_DIR"
terraform init -input=false >/dev/null

in_state() {
  terraform state show "$1" >/dev/null 2>&1
}

tf_import() {
  local addr="$1"
  local id="$2"
  if in_state "$addr"; then
    echo "  skip (already in state): $addr"
    return 0
  fi
  echo "  import: $addr <= $id"
  terraform import "$addr" "$id"
}

node_sg_id() {
  aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER}-node*" "Name=group-name,Values=*node*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -E '^sg-' || true
}

cluster_sg_id() {
  aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER}-cluster*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -E '^sg-' || true
}

import_sg_rules() {
  local node_sg cluster_sg
  node_sg="$(node_sg_id)"
  cluster_sg="$(cluster_sg_id)"

  if [[ -z "$node_sg" || "$node_sg" == "None" ]]; then
    echo "Could not resolve node security group for cluster ${CLUSTER}."
    exit 1
  fi
  if [[ -z "$cluster_sg" || "$cluster_sg" == "None" ]]; then
    echo "Could not resolve cluster security group for cluster ${CLUSTER}."
    exit 1
  fi

  echo "Node SG: $node_sg  Cluster SG: $cluster_sg"

  tf_import 'module.eks.module.eks.aws_security_group_rule.node["egress_all"]' \
    "${node_sg}_egress_all_0_0_0.0.0.0/0" \
    || tf_import 'module.eks.module.eks.aws_security_group_rule.node["egress_all"]' \
    "${node_sg}_egress_-1_0_0_0.0.0.0/0"

  tf_import 'module.eks.module.eks.aws_security_group_rule.node["ingress_cluster_8443_webhook"]' \
    "${node_sg}_ingress_tcp_8443_8443_${cluster_sg}"
}

delete_sg_rules() {
  local node_sg cluster_sg
  node_sg="$(node_sg_id)"
  cluster_sg="$(cluster_sg_id)"

  if [[ -z "$node_sg" || "$node_sg" == "None" ]]; then
    echo "Could not resolve node security group."
    exit 1
  fi

  echo "Force-deleting duplicate rules on $node_sg ..."

  if aws ec2 describe-security-group-rules --region "$AWS_REGION" \
    --filters "Name=group-id,Values=${node_sg}" \
    --query 'SecurityGroupRules[?IsEgress==`true` && CidrIpv4==`0.0.0.0/0` && IpProtocol==`-1`].SecurityGroupRuleId' \
    --output text | grep -q sgr-; then
  local egress_ids=()
  while IFS= read -r rule_id; do
    [[ -n "$rule_id" ]] && egress_ids+=("$rule_id")
  done < <(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
    --filters "Name=group-id,Values=${node_sg}" \
    --query 'SecurityGroupRules[?IsEgress==`true` && CidrIpv4==`0.0.0.0/0` && IpProtocol==`-1`].SecurityGroupRuleId' \
    --output text | tr '\t' '\n')
    aws ec2 revoke-security-group-egress --region "$AWS_REGION" \
      --group-id "$node_sg" --security-group-rule-ids "${egress_ids[@]}"
    echo "  deleted egress_all (${#egress_ids[@]} rule(s))"
  else
    echo "  no egress_all rule found (already gone?)"
  fi

  if [[ -n "$cluster_sg" && "$cluster_sg" != "None" ]]; then
  if aws ec2 describe-security-group-rules --region "$AWS_REGION" \
    --filters "Name=group-id,Values=${node_sg}" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol==\`tcp\` && FromPort==\`8443\` && ReferencedGroupInfo.GroupId==\`${cluster_sg}\`].SecurityGroupRuleId" \
    --output text | grep -q sgr-; then
    local ingress_ids=()
    while IFS= read -r rule_id; do
      [[ -n "$rule_id" ]] && ingress_ids+=("$rule_id")
    done < <(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
      --filters "Name=group-id,Values=${node_sg}" \
      --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol==\`tcp\` && FromPort==\`8443\` && ReferencedGroupInfo.GroupId==\`${cluster_sg}\`].SecurityGroupRuleId" \
      --output text | tr '\t' '\n')
    aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
      --group-id "$node_sg" --security-group-rule-ids "${ingress_ids[@]}"
    echo "  deleted ingress_cluster_8443_webhook (${#ingress_ids[@]} rule(s))"
  else
    echo "  no 8443 ingress rule found (already gone?)"
  fi
  fi
}

import_kms_alias() {
  tf_import 'module.eks.module.eks.module.kms.aws_kms_alias.this["cluster"]' "$KMS_ALIAS"
}

delete_kms_alias() {
  if aws kms describe-key --region "$AWS_REGION" --key-id "$KMS_ALIAS" >/dev/null 2>&1; then
    echo "Deleting KMS alias $KMS_ALIAS (key is retained) ..."
    aws kms delete-alias --region "$AWS_REGION" --alias-name "$KMS_ALIAS"
  else
    echo "  KMS alias $KMS_ALIAS not found (already gone?)"
  fi
}

import_cloudwatch_log_group() {
  local log_group="/aws/eks/${CLUSTER}/cluster"
  if ! aws logs describe-log-groups --region "$AWS_REGION" \
    --log-group-name-prefix "$log_group" \
    --query "logGroups[?logGroupName=='${log_group}'].logGroupName | [0]" \
    --output text | grep -q "$log_group"; then
    echo "  CloudWatch log group ${log_group} not found; apply will create it."
    return 0
  fi
  tf_import 'module.eks.module.eks.aws_cloudwatch_log_group.this[0]' "$log_group"
}

import_nat_gateway() {
  local vpc_id nat_id state_nat
  vpc_id="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "  VPC not found; skip NAT gateway import."
    return 0
  fi

  nat_id="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available" \
    --query 'NatGateways[0].NatGatewayId' --output text)"
  if [[ -z "$nat_id" || "$nat_id" == "None" ]]; then
    echo "  no available NAT gateway in VPC; apply will create one."
    return 0
  fi

  if in_state 'module.vpc.module.vpc.aws_nat_gateway.this[0]'; then
    state_nat="$(terraform state show -no-color 'module.vpc.module.vpc.aws_nat_gateway.this[0]' 2>/dev/null \
      | awk '/^    id / { print $3 }')"
    if [[ -n "$state_nat" && "$state_nat" != "$nat_id" ]]; then
      echo "  replacing stale NAT in state (${state_nat} -> ${nat_id})"
      terraform state rm 'module.vpc.module.vpc.aws_nat_gateway.this[0]'
    fi
  fi

  local failed_nat
  while IFS= read -r failed_nat; do
    [[ -z "$failed_nat" || "$failed_nat" == "$nat_id" ]] && continue
    echo "  deleting failed NAT ${failed_nat} ..."
    aws ec2 delete-nat-gateway --region "$AWS_REGION" --nat-gateway-id "$failed_nat" >/dev/null 2>&1 || true
  done < <(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=failed" \
    --query 'NatGateways[*].NatGatewayId' --output text | tr '\t' '\n')

  tf_import 'module.vpc.module.vpc.aws_nat_gateway.this[0]' "$nat_id"
}

import_vpc_public_subnets() {
  local vpc_id
  vpc_id="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}" \
    --query 'Vpcs[0].VpcId' --output text)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    echo "VPC not found for ${NAME_PREFIX}; skip public subnet import."
    return 0
  fi

  local pub0 pub1
  pub0="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=cidr-block,Values=10.1.32.0/20" \
    --query 'Subnets[0].SubnetId' --output text)"
  pub1="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=cidr-block,Values=10.1.48.0/20" \
    --query 'Subnets[0].SubnetId' --output text)"

  [[ "$pub0" != "None" && -n "$pub0" ]] && \
    tf_import 'module.vpc.module.vpc.aws_subnet.public[0]' "$pub0"
  [[ "$pub1" != "None" && -n "$pub1" ]] && \
    tf_import 'module.vpc.module.vpc.aws_subnet.public[1]' "$pub1"
}

import_efs_mount_targets() {
  local fs_id mt_ids
  fs_id="$(aws efs describe-file-systems --region "$AWS_REGION" \
    --query "FileSystems[?Name=='${NAME_PREFIX}-models'].FileSystemId | [0]" --output text)"
  if [[ -z "$fs_id" || "$fs_id" == "None" ]]; then
    echo "EFS ${NAME_PREFIX}-models not found; skip mount target import."
    return 0
  fi

  local mt_ids=()
  while IFS= read -r mt; do
    [[ -n "$mt" ]] && mt_ids+=("$mt")
  done < <(aws efs describe-mount-targets --region "$AWS_REGION" \
    --file-system-id "$fs_id" \
    --query 'MountTargets[*].MountTargetId' --output text | tr '\t' '\n' | sort)
  if [[ ${#mt_ids[@]} -eq 0 ]]; then
    echo "  no mount targets in AWS (apply will create them)"
    return 0
  fi
  local i=0
  for mt in "${mt_ids[@]}"; do
    tf_import "module.efs.aws_efs_mount_target.this[${i}]" "$mt"
    i=$((i + 1))
  done
}

import_s3_models_bucket() {
  local bucket="${NAME_PREFIX}-model-artifacts"
  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "S3 bucket ${bucket} not found; apply will create it."
    return 0
  fi
  echo "S3 bucket: ${bucket}"
  tf_import 'module.s3_models.aws_s3_bucket.model_artifacts' "$bucket"
  tf_import 'module.s3_models.aws_s3_bucket_versioning.model_artifacts' "$bucket"
  tf_import 'module.s3_models.aws_s3_bucket_server_side_encryption_configuration.model_artifacts' "$bucket"
  tf_import 'module.s3_models.aws_s3_bucket_public_access_block.model_artifacts' "$bucket"
  tf_import 'module.s3_models.aws_s3_bucket_policy.model_artifacts' "$bucket"
}

run_import() {
  case "$IMPORT_FILTER" in
    all)
      echo "=== Import VPC public subnets ==="
      import_vpc_public_subnets
      echo "=== Import NAT gateway ==="
      import_nat_gateway
      echo "=== Import EFS mount targets ==="
      import_efs_mount_targets
      echo "=== Import S3 model artifacts bucket ==="
      import_s3_models_bucket
      echo "=== Import CloudWatch log group ==="
      import_cloudwatch_log_group
      echo "=== Import KMS alias ==="
      import_kms_alias
      echo "=== Import EKS node SG rules ==="
      import_sg_rules
      ;;
    sg) echo "=== Import EKS node SG rules ==="; import_sg_rules ;;
    kms) echo "=== Import KMS alias ==="; import_kms_alias ;;
    vpc)
      echo "=== Import VPC public subnets ==="
      import_vpc_public_subnets
      echo "=== Import NAT gateway ==="
      import_nat_gateway
      ;;
    efs) echo "=== Import EFS mount targets ==="; import_efs_mount_targets ;;
    s3) echo "=== Import S3 model artifacts bucket ==="; import_s3_models_bucket ;;
    eks)
      echo "=== Import CloudWatch log group ==="
      import_cloudwatch_log_group
      echo "=== Import NAT gateway ==="
      import_nat_gateway
      ;;
    *) echo "Unknown --import-only filter: $IMPORT_FILTER"; exit 1 ;;
  esac
}

run_delete() {
  echo "=== Force-delete KMS alias ==="
  delete_kms_alias
  echo "=== Force-delete duplicate node SG rules ==="
  delete_sg_rules
}

echo "Environment: ${TF_ENVIRONMENT}  Cluster: ${CLUSTER}  Mode: ${MODE}"
if [[ "$MODE" == "delete" ]]; then
  run_delete
  echo ""
  echo "Done. Re-run: TF_ENVIRONMENT=${TF_ENVIRONMENT} make plan"
else
  run_import
  echo ""
  echo "Done. Re-run: TF_ENVIRONMENT=${TF_ENVIRONMENT} make plan"
fi
