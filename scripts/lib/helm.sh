#!/usr/bin/env bash
# Retry helm upgrade --install (Helm chart downloads can fail transiently).
set -euo pipefail

helm_upgrade_install() {
  local attempt=1
  local max_attempts="${HELM_MAX_ATTEMPTS:-5}"
  local delay="${HELM_RETRY_DELAY_SECONDS:-15}"

  while true; do
    if helm upgrade --install "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      echo "Helm upgrade --install failed after ${max_attempts} attempts: $*"
      return 1
    fi
    echo "Helm failed (attempt ${attempt}/${max_attempts}), retrying in ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}
