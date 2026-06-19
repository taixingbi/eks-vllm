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
  echo "Cluster: $(cd "$TF_DIR" && terraform output -raw cluster_name 2>/dev/null || echo unknown)"
  echo ""
  read -r -p "Type '${TF_ENVIRONMENT}' to continue: " answer
  [[ "${answer}" == "${TF_ENVIRONMENT}" ]]
}
