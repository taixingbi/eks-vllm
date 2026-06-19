#!/usr/bin/env bash
# Sync HuggingFace token to AWS Secrets Manager for External Secrets Operator.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/env.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
HF_TOKEN="${HF_TOKEN:?HF_TOKEN is required}"

if aws secretsmanager describe-secret --secret-id "${HF_SECRET_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "${HF_SECRET_NAME}" \
    --secret-string "${HF_TOKEN}" \
    --region "${AWS_REGION}"
  echo "Updated secret ${HF_SECRET_NAME}"
else
  aws secretsmanager create-secret \
    --name "${HF_SECRET_NAME}" \
    --secret-string "${HF_TOKEN}" \
    --region "${AWS_REGION}"
  echo "Created secret ${HF_SECRET_NAME}"
fi
