#!/usr/bin/env bash
# TUI interaction system for bootstrap remediation

COOKIE_DIR="./ai-configuration/remediation_cookies"
LOG_FILE="./ai-configuration/logs/tui.log"

init_cookie_dir() {
  mkdir -p "$COOKIE_DIR"
}

log_interaction() {
  echo "$(date +'%FT%T') - $*" >> "$LOG_FILE"
}

prompt_remediation() {
  local component=$1
  local message=$2
  
  whiptail --title "Remediation Required" \
    --yesno "$message" \
    --yes-button "Fix Now" \
    --no-button "Later" \
    10 60
  
  case $? in
    0) return 0 ;;
    1) touch "$COOKIE_DIR/${component}.cookie"
       log_interaction "DEFERRED: ${component}"
       return 1 ;;
    *) return 2 ;;
  esac
}
