#!/usr/bin/env bash
# Build System Integration Wrapper
#
# Safe unified build entry point that checks feature flags and delegates
# to build.sh for each enabled component. Used by bootstrap and tests.

set -euo pipefail

source "$(dirname "$0")/common_paths.sh"

# ============================================================================
# Global Variables
# ============================================================================

# Feature flags (read from environment)
# BUILDLLAMADEFAULT - Build llama.cpp if set to 1
# INSTALL_VLLM - Build vLLM if set to 1
# INSTALL_TTS_DEFAULT - Build Kokoro TTS if set to 1
# VLLM_VENV - Path to vLLM venv (if empty, triggers build)

# ============================================================================
# Build Functions
# ============================================================================

# Log - Write log message with prefix
#
# Arguments: All message components ($@)
# Outputs: Formatted message to stdout
# Returns: 0 (always succeeds)
# Globals: None
Log() {
  echo "[integrate_build] $*"
}

# IntegrateBuild - Orchestrate component builds based on feature flags
#
# Arguments: None
# Outputs: Build progress via Log
# Returns: 0 if all builds succeeded, 1 if any failed
# Globals: Reads BUILDLLAMADEFAULT, INSTALL_VLLM, INSTALL_TTS_DEFAULT, VLLM_VENV, SCRIPT_DIR
IntegrateBuild() {
  local status=0               # Overall build status (0=success, 1=failure)
  
  Log "Starting integrated build process"
  
  # Build llama.cpp if enabled
  if [[ "${BUILDLLAMADEFAULT:-0}" -eq 1 ]]; then
    Log "Attempting llama.cpp build..."
    
    if "${SCRIPT_DIR}/build.sh" --component llama; then
      Log "✓ llama.cpp build succeeded"
    else
      Log "✗ llama.cpp build failed"
      status=1
    fi
  fi

  # Build vLLM if enabled and venv missing/broken
  if [[ "${INSTALL_VLLM:-0}" -eq 1 ]] && [[ -z "${VLLM_VENV:-}" || ! -f "${VLLM_VENV}/bin/activate" ]]; then
    Log "Attempting vLLM build..."
    
    if "${SCRIPT_DIR}/build.sh" --component vllm; then
      Log "✓ vLLM build succeeded"
    else
      Log "✗ vLLM build failed"
      status=1
    fi
  fi

  # Build Kokoro TTS if enabled
  if [[ "${INSTALL_TTS_DEFAULT:-0}" -eq 1 ]]; then
    Log "Attempting Kokoro TTS build..."
    
    if "${SCRIPT_DIR}/build.sh" --component kokoro; then
      Log "✓ Kokoro build succeeded"
    else
      Log "✗ Kokoro build failed"
      status=1
    fi
  fi

  if [[ $status -eq 0 ]]; then
    Log "All builds completed successfully"
  else
    Log "One or more builds failed"
  fi

  return $status
}

# ============================================================================
# Main Execution
# ============================================================================

# CoreExec - Main execution function
#
# Arguments: None
# Outputs: Delegates to IntegrateBuild
# Returns: Exit code from IntegrateBuild
# Globals: None
CoreExec() {
  IntegrateBuild
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec
