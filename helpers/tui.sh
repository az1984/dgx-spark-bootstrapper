#!/usr/bin/env bash
# TUI interaction system for bootstrap remediation
#
# Provides whiptail-based dialog prompts for user interaction during
# bootstrap process, with cookie-based deferred fix tracking.

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

COOKIE_DIR="/opt/ai-configuration/remediation_cookies"  # Deferred fix tracking
LOG_FILE="/opt/ai-configuration/logs/tui.log"          # TUI interaction log

# ============================================================================
# Functions
# ============================================================================

# InitCookieDir - Ensure cookie and log directories exist
#
# Arguments: None
# Outputs: None
# Returns: 0 (always succeeds)
# Globals: Reads COOKIE_DIR, LOG_FILE
InitCookieDir() {
  mkdir -p "$COOKIE_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"
}

# LogInteraction - Record TUI interaction to log file
#
# Arguments: All strings to log ($@)
# Outputs: Timestamped log entry to LOG_FILE
# Returns: 0 (always succeeds)
# Globals: Reads LOG_FILE
LogInteraction() {
  echo "$(date +'%FT%T') - $*" >> "$LOG_FILE"
}

# PromptVersionMismatch - Show version conflict dialog
#
# Arguments:
#   $1 - component name (string)
#   $2 - current version (string)
#   $3 - required version (string)
# Outputs: Whiptail dialog to user
# Returns: 0 if user selects "Upgrade", 1 if "Skip"
# Globals: None
PromptVersionMismatch() {
  local component="$1"    # Component with version mismatch
  local current="$2"      # Currently installed version
  local required="$3"     # Version requirement
  
  whiptail --title "Version Mismatch" \
    --yesno "Component: $component\nCurrent: $current\nRequired: $required\n\nUpgrade now?" \
    --yes-button "Upgrade" \
    --no-button "Skip" \
    12 60
}

# PromptRemediation - Show remediation required dialog
#
# Arguments:
#   $1 - message to display (string), OR component name if 2 args
#   $2 - message to display (string), optional
# Outputs: Whiptail dialog to user
# Returns:
#   0 - User selected "Fix Now"
#   1 - User selected "Later" (creates cookie)
#   2 - User cancelled (ESC key)
# Globals: Reads/writes COOKIE_DIR
PromptRemediation() {
  local component="bootstrap"  # Component name for cookie file
  local message=""            # Message to display in dialog
  
  # Handle both single-arg and two-arg calling conventions
  if [[ $# -eq 1 ]]; then
    message="$1"
  elif [[ $# -eq 2 ]]; then
    component="$1"
    message="$2"
  else
    echo "Error: PromptRemediation requires 1 or 2 arguments" >&2
    return 2
  fi
  
  whiptail --title "Remediation Required" \
    --yesno "$message" \
    --yes-button "Fix Now" \
    --no-button "Later" \
    10 60
  
  local exit_code=$?  # Exit code from whiptail
  
  case $exit_code in
    0)
      # User selected "Fix Now"
      return 0
      ;;
    1)
      # User selected "Later" - create cookie
      touch "$COOKIE_DIR/${component}.cookie"
      LogInteraction "DEFERRED: ${component}"
      return 1
      ;;
    *)
      # User cancelled (ESC)
      return 2
      ;;
  esac
}

# CoreExec - Initialize TUI system
#
# Arguments: None
# Outputs: None
# Returns: 0 (always succeeds)
# Globals: None
CoreExec() {
  InitCookieDir
}

# ============================================================================
# Entry Point
# ============================================================================

# Initialize on source (this script is sourced, not executed)
CoreExec
