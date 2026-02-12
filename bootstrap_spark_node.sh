#!/usr/bin/env bash

# [Previous content until Main() preserved...]

Main() {
  RequireRoot
  
  # Check for pending remediations
  if ls "./ai-configuration/remediation_cookies/"*.cookie 1>/dev/null 2>&1; then
    Log "Pending remediations detected:"
    local pending_items=$(ls "./ai-configuration/remediation_cookies/"*.cookie | xargs -n1 basename | sed 's/.cookie$//')
    echo "$pending_items"
    
    # Show TUI prompt
    source "$(dirname "$0")/helpers/tui.sh"
    prompt_remediation "Found pending remediations for:\n$pending_items\nFix now?"
    case $? in
      0) Log "Proceeding with remediation" ;;
      1) Log "User deferred fixes"; exit 0 ;;
      *) Log "User cancelled"; exit 1 ;;
    esac
  fi

  # Directory skeleton first
  CheckDirSkeleton || true
  ApplyDirSkeletonFixes

  # Switch logging to /opt now that directory skeleton is enforced
  USE_OPT_LOGS=1
  Log "Switched logging to ${OPT_LOG_DIR}"

  # Version validation
  VersionCheck

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
