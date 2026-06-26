#!/usr/bin/env bash
# Terminate Karpenter G5 GPU nodes (kubectl + EC2 fallback).
set -euo pipefail

normalize_count() {
  local v
  v=$(printf '%s' "$1" | tr -d '[:space:]')
  if [[ -z "${v}" ]] || [[ ! "${v}" =~ ^[0-9]+$ ]]; then
    echo 0
  else
    echo "${v}"
  fi
}

terminate_gpu_nodes() {
  local cluster_name="${1:?cluster name required}"
  local region="${2:-${AWS_REGION:-us-east-1}}"
  local max_wait="${3:-900}"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not available; skipping in-cluster GPU cleanup"
  else
    echo "Deleting GPU NodeClaims..."
    kubectl delete nodeclaims --all --ignore-not-found --wait=false 2>/dev/null || true

    echo "Force-deleting GPU Kubernetes nodes..."
    kubectl delete node -l workload=gpu --ignore-not-found --force --grace-period=0 2>/dev/null || true
  fi

  terminate_g5_ec2_instances "${cluster_name}" "${region}"

  if ! command -v kubectl >/dev/null 2>&1; then
    return 0
  fi

  echo "Waiting up to ${max_wait}s for GPU nodes to disappear..."
  local elapsed=0 k8s_count ec2_count
  while [[ "${elapsed}" -lt "${max_wait}" ]]; do
    k8s_count=$(normalize_count "$(kubectl get nodes -l workload=gpu -o name 2>/dev/null | wc -l | awk '{print $1}')")
    ec2_count=$(normalize_count "$(count_g5_ec2_instances "${cluster_name}" "${region}")")
    if [[ "${k8s_count}" -eq 0 ]] && [[ "${ec2_count}" -eq 0 ]]; then
      echo "All GPU nodes terminated."
      return 0
    fi
    echo "  GPU nodes: k8s=${k8s_count}, ec2(g5)=${ec2_count} — waiting..."
    sleep 20
    elapsed=$((elapsed + 20))
    if [[ $((elapsed % 60)) -eq 0 ]] && [[ "${elapsed}" -gt 0 ]]; then
      terminate_g5_ec2_instances "${cluster_name}" "${region}" || true
    fi
  done

  echo "Warning: GPU nodes may still be terminating after ${max_wait}s."
  return 0
}

count_g5_ec2_instances() {
  local cluster_name=$1
  local region=$2
  aws ec2 describe-instances \
    --region "${region}" \
    --filters \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      "Name=instance-type,Values=g5.2xlarge,g5.4xlarge,g5.8xlarge,g5.12xlarge,g5.16xlarge,g5.24xlarge,g5.48xlarge" \
      "Name=tag:karpenter.sh/discovery,Values=${cluster_name}" \
    --query 'length(Reservations[].Instances[])' \
    --output text 2>/dev/null || echo "0"
}

terminate_g5_ec2_instances() {
  local cluster_name=$1
  local region=$2

  if ! command -v aws >/dev/null 2>&1; then
    return 0
  fi

  local ids
  ids=$(aws ec2 describe-instances \
    --region "${region}" \
    --filters \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      "Name=instance-type,Values=g5.2xlarge,g5.4xlarge,g5.8xlarge,g5.12xlarge,g5.16xlarge,g5.24xlarge,g5.48xlarge" \
      "Name=tag:karpenter.sh/discovery,Values=${cluster_name}" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)

  if [[ -z "${ids}" || "${ids}" == "None" ]]; then
    return 0
  fi

  echo "Terminating G5 EC2 instances: ${ids}"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "${region}" --instance-ids ${ids} >/dev/null 2>&1 || {
    echo "Warning: ec2 terminate-instances failed (check AWS credentials/IAM)."
  }
}
