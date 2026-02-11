#!/usr/bin/env bash
# [Previous content until Main() preserved...]

Main() {
  RequireRoot
  
  # [Existing pre-check code preserved...]

  # Component Building Section
  if [[ "${BUILDLLAMADEFAULT}" -eq 1 || "${INSTALL_COMFYUI_DEFAULT}" -eq 1 || "${INSTALL_TTS_DEFAULT}" -eq 1 ]]; then
    Log "Building AI components via unified build system"
    
    if [[ "${BUILDLLAMADEFAULT}" -eq 1 ]]; then
      "$(dirname "$0")/helpers/build.sh" --component llama --node 1
    fi
    
    if [[ -z "${VLLM_VENV}" || ! -d "${VLLM_VENV}" ]]; then
      "$(dirname "$0")/helpers/build.sh" --component vllm --node 1  
    fi

    if [[ "${INSTALL_TTS_DEFAULT}" -eq 1 ]]; then
      "$(dirname "$0")/helpers/build.sh" --component kokoro --node 1
    fi
  fi

  # [Rest of original Main() implementation...]
}

# [Remaining file content...]
