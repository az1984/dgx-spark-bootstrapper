#!/usr/bin/env bash
# Build Integration Test Script

set -euo pipefail

source "$(dirname "$0")/integrate_build.sh"

# Test environment setup
export BUILDLLAMADEFAULT=1
export INSTALL_VLLM=1 
export INSTALL_TTS_DEFAULT=1
export DIR="$(dirname "$0")"
export VLLM_VENV=""

Log() {
  echo "[TEST] $*"
}

# Execute test
if integrate_build; then
  echo "✅ Build integration test passed"
else
  echo "❌ Build integration test failed"
  exit 1
fi
