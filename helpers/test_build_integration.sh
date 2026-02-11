#!/usr/bin/env bash
# Build Integration Test Script

set -euo pipefail

# Initialize environment
source "$(dirname "$0")/common_paths.sh"

# Test configuration
export BUILDLLAMADEFAULT=1
export INSTALL_VLLM=1
export INSTALL_TTS_DEFAULT=1
export VLLM_VENV=""

Log() {
  echo "[TEST] $*"
}

if "${SCRIPT_DIR}/integrate_build.sh"; then
  echo "✅ Build integration test passed"
  exit 0
else
  echo "❌ Build integration test failed" 
  exit 1
fi
