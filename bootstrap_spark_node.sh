#!/usr/bin/env bash
# [Previous file content remains unchanged until Main() function]

Main() {
  RequireRoot
  
  # Check for pending remediations
  if [[ -d "./ai-configuration/remediation_cookies" ]]; then
    local pending_items=()
    for cookie in "./ai-configuration/remediation_cookies/"*.cookie; do
      [[ -e "$cookie" ]] || continue
      pending_items+=("$(basename "${cookie%.cookie}")")
    done

    if [[ ${#pending_items[@]} -gt 0 ]]; then
      Log "Pending remediations detected:"
      Log "$(printf '%s\n' "${pending_items[@]}")"
      
      source "$(dirname "$0")/helpers/tui.sh"
      if ! prompt_remediation "Found pending fixes for: ${pending_items[*]}\nProceed with remediation?"; then
        Log "Remediation deferred by user"
        return 0
      fi
    fi
  fi

  VersionCheck
  
  # [Rest of original Main() content]
  Log "=== bootstrap start ==="
  CheckDirSkeleton || true
  ApplyDirSkeletonFixes
  USE_OPT_LOGS=1
  Log "Switched logging to ${OPT_LOG_DIR}"

  # [...rest of original Main() implementation...]
}

# [Remaining file content]
