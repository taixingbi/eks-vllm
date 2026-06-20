#!/usr/bin/env bash
# Prompt before destructive operations unless AUTO_APPROVE=1.
set -euo pipefail

confirm_action() {
  local action=$1

  if [[ "${AUTO_APPROVE:-}" == "1" ]]; then
    return 0
  fi

  echo ""
  echo "About to ${action} for environment: ${TF_ENVIRONMENT}"
  if [[ -f "${ROOT}/scripts/lib/cluster.sh" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT}/scripts/lib/cluster.sh"
    CLUSTER_DISPLAY=$(resolve_cluster_name 2>/dev/null || echo "qwen-vllm-${TF_ENVIRONMENT}")
    if cluster_exists "${CLUSTER_DISPLAY}" 2>/dev/null; then
      echo "Cluster: ${CLUSTER_DISPLAY} (exists)"
    else
      echo "Cluster: ${CLUSTER_DISPLAY} (not deployed)"
    fi
  else
    echo "Cluster: $(cd "$TF_DIR" 2>/dev/null && terraform output -raw cluster_name 2>/dev/null || echo unknown)"
  fi
  read -r -p "Type '${TF_ENVIRONMENT}' to continue: " answer
  [[ "${answer}" == "${TF_ENVIRONMENT}" ]]
}
