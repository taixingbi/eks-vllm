#!/usr/bin/env bash
# Helpers for deleting optional Kubernetes resources.
set -euo pipefail

kubectl_delete() {
  kubectl delete "$@" --ignore-not-found --wait=false 2>/dev/null || true
}

kubectl_delete_crd_kind() {
  local crd=$1
  shift
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    kubectl_delete "$@"
  fi
}
