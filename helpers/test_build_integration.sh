#!/usr/bin/env bash
# Build Integration Test Script
#
# Tests the integrate_build.sh wrapper by simulating a full build cycle
# with feature flags enabled.

set -euo pipefail

# ============================================================================
# Test Configuration
# ============================================================================

export BUILDLLAMADEFAULT=1           # Enable llama.cpp build
export INSTALL_VLLM=1                # Enable vLLM build
export INSTALL_TTS_DEFAULT=1         # Enable TTS (Kokoro) build
export VLLM_VENV=""                  # Force vLLM detection as missing

# ============================================================================
# Utility Functions
# ============================================================================

# Log - Write test log message
#
# Arguments: All message components ($@)
# Outputs: Formatted test message to stdout
# Returns: 0 (always succeeds)
# Globals: None
Log() {
  echo "[TEST] $*"
}

# ============================================================================
# Main Execution
# ============================================================================

# CoreExec - Main test execution function
#
# Arguments: None
# Outputs: Test results via Log
# Returns: 0 on success, 1 on failure
# Globals: None
CoreExec() {
  local script_dir=""            # Script directory path
  
  # Initialize environment
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  
  # Source common paths if available
  if [[ -f "${script_dir}/common_paths.sh" ]]; then
    # shellcheck disable=SC1090
    source "${script_dir}/common_paths.sh"
  fi

  Log "Starting build integration test"
  Log "Configuration:"
  Log "  BUILDLLAMADEFAULT=${BUILDLLAMADEFAULT}"
  Log "  INSTALL_VLLM=${INSTALL_VLLM}"
  Log "  INSTALL_TTS_DEFAULT=${INSTALL_TTS_DEFAULT}"

  # Run integration build
  if "${script_dir}/integrate_build.sh"; then
    Log "✅ Build integration test passed"
    return 0
  else
    Log "❌ Build integration test failed"
    return 1
  fi
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec
