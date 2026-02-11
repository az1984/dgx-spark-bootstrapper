#!/usr/bin/env bash
# Build System Integration Wrapper
# Safely connects bootstrap to build helpers

set -euo pipefail

integrate_build() {
  Log "Starting integrated build process"
  local status=0
  
  if [[ "${BUILDLLAMADEFAULT:-0}" -eq 1 ]]; then
    "$(dirname "$0")/build.sh" --component llama --node 1 || {
      Log "llama.cpp build failed"
      status=1
    }
  fi

  if [[ "${INSTALL_VLLM:-0}" -eq 1 ]] && [[ -z "${VLLM_VENV:-}" || ! -d "${VLLM_VENV}" ]]; then
    "$(dirname "$0")/build.sh" --component vllm --node 1 || {
      Log "vLLM build failed" 
      status=1
    }
  fi

  if [[ "${INSTALL_TTS_DEFAULT:-0}" -eq 1 ]]; then
    "$(dirname "$0")/build.sh" --component kokoro --node 1 || {
      Log "Kokoro build failed"
      status=1
    }
  fi

  return $status
}

# Usage example:
# integrate_build || exit 1
