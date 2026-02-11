#!/usr/bin/env bash
# Build System Integration Wrapper
# Safe unified build entry point

set -euo pipefail

source "$(dirname "$0")/common_paths.sh"

integrate_build() {
  Log "Starting integrated build process"
  local status=0
  
  if [[ "${BUILDLLAMADEFAULT:-0}" -eq 1 ]]; then
    "${SCRIPT_DIR}/build.sh" --component llama --node 1 || {
      Log "llama.cpp build failed"
      status=1
    }
  fi

  if [[ "${INSTALL_VLLM:-0}" -eq 1 ]] && [[ -z "${VLLM_VENV:-}" || ! -d "${VLLM_VENV}" ]]; then
    "${SCRIPT_DIR}/build.sh" --component vllm --node 1 || {
      Log "vLLM build failed" 
      status=1
    }
  fi

  if [[ "${INSTALL_TTS_DEFAULT:-0}" -eq 1 ]]; then
    "${SCRIPT_DIR}/build.sh" --component kokoro --node 1 || {
      Log "Kokoro build failed"
      status=1
    }
  fi

  return $status
}
