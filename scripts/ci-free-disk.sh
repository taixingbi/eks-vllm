#!/usr/bin/env bash
# Reclaim runner disk before large Docker pulls (vLLM base image is ~9 GB).
set -euo pipefail

echo "Disk before cleanup:"
df -h / || df -h

# GitHub-hosted runners ship with large unused toolchains.
sudo rm -rf /usr/share/dotnet 2>/dev/null || true
sudo rm -rf /usr/local/lib/android 2>/dev/null || true
sudo rm -rf /opt/ghc 2>/dev/null || true
sudo rm -rf /opt/hostedtoolcache/CodeQL 2>/dev/null || true
sudo rm -rf "${AGENT_TOOLSDIRECTORY:-}" 2>/dev/null || true

# Remove cached images from earlier workflow steps.
docker system prune -af 2>/dev/null || true

echo "Disk after cleanup:"
df -h / || df -h
