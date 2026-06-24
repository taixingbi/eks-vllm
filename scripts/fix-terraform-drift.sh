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
      IMPORT_FILTER="${2:?--import-only requires: sg|kms|vpc|efs|all}"
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
  terraform state list 2>/dev/null | grep -qF "$1"
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
    mapfile -t egress_ids < <(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
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
    mapfile -t ingress_ids < <(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
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

  mapfile -t mt_ids < <(aws efs describe-mount-targets --region "$AWS_REGION" \
    --file-system-id "$fs_id" \
    --query 'MountTargets[*].MountTargetId' --output text | tr '\t' '\n' | sort)
  if [[ ${#mt_ids[@]} -eq 0 ]]; then
    echo "  no mount targets in AWS (apply will create them)"
    return 0
  fi
  local i=0
  for mt in "${mt_ids[@]}"; do
    tf_import "module.efs.aws_efs_mount_target.this[${i}]" "$mt"
  done
}

run_import() {
  case "$IMPORT_FILTER" in
    all)
      echo "=== Import VPC public subnets ==="
      import_vpc_public_subnets
      echo "=== Import EFS mount targets ==="
      import_efs_mount_targets
      echo "=== Import KMS alias ==="
      import_kms_alias
      echo "=== Import EKS node SG rules ==="
      import_sg_rules
      ;;
    sg) echo "=== Import EKS node SG rules ==="; import_sg_rules ;;
    kms) echo "=== Import KMS alias ==="; import_kms_alias ;;
    vpc) echo "=== Import VPC public subnets ==="; import_vpc_public_subnets ;;
    efs) echo "=== Import EFS mount targets ==="; import_efs_mount_targets ;;
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
