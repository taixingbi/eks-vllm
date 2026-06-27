#!/usr/bin/env bash
# Build Kong declarative config from template and API keys.
# Usage: build-kong-config.sh <output-path> [key1 key2 ...]
#   Or set PLATFORM_GATEWAY_API_KEY / PLATFORM_GATEWAY_API_KEYS (comma-separated).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

OUT="${1:?output path required}"
shift || true

KEYS=("$@")
if [[ ${#KEYS[@]} -eq 0 ]]; then
  if [[ -n "${PLATFORM_GATEWAY_API_KEYS:-}" ]]; then
    IFS=',' read -ra KEYS <<< "${PLATFORM_GATEWAY_API_KEYS}"
  elif [[ -n "${PLATFORM_GATEWAY_API_KEY:-}" ]]; then
    KEYS=("${PLATFORM_GATEWAY_API_KEY}")
  elif [[ "${TF_ENVIRONMENT}" == "dev" ]]; then
    KEYS=("dev-change-me")
    echo "Warning: using placeholder API key 'dev-change-me' — set PLATFORM_GATEWAY_API_KEY"
  else
    echo "ERROR: no API keys provided for Kong config (prod requires Secrets Manager sync)"
    exit 1
  fi
fi

mkdir -p "$(dirname "${OUT}")"

python3 - "${ROOT}/kubernetes/gateway/kong-dbless-config.yaml.template" "${OUT}" \
  "${GATEWAY_RATE_LIMIT_PER_MINUTE}" "${GATEWAY_MAX_BODY_MB}" "${KEYS[@]}" <<'PY'
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
rate_limit = sys.argv[3]
max_body = sys.argv[4]
keys = [k.strip() for k in sys.argv[5:] if k.strip()]

consumers_lines = ["consumers:"]
for i, key in enumerate(keys, start=1):
    username = f"platform-client-{i}"
    consumers_lines.append(f"  - username: {username}")
    consumers_lines.append("    keyauth_credentials:")
    consumers_lines.append(f"      - key: \"{key}\"")

consumers_block = "\n".join(consumers_lines)
text = template_path.read_text()
text = text.replace("__GATEWAY_RATE_LIMIT_PER_MINUTE__", rate_limit)
text = text.replace("__GATEWAY_MAX_BODY_MB__", max_body)
text = text.replace("__KONG_CONSUMERS_BLOCK__", consumers_block)
out_path.write_text(text)
PY

echo "Kong declarative config written to ${OUT}"
