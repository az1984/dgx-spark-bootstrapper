#!/usr/bin/env bash
# Unified build dispatcher with standardized path handling

set -euo pipefail

source "$(dirname "$0")/common_paths.sh"

# ============================================================================
# Global Variables
# ============================================================================

COMPONENT=""        # Component name to build (vllm|llama|kokoro|whisper|dia|comfyui)

# ============================================================================
# Functions
# ============================================================================

# ShowUsage - Display help text and exit
#
# Arguments: None
# Outputs: Usage text to stdout
# Returns: Exits with code 1
# Globals: None
ShowUsage() {
  cat <<'USAGE'
Usage: build.sh --component <name>

Arguments:
  --component <name>    Component to build
                        Options: vllm, llama, kokoro, whisper, dia, comfyui

Examples:
  ./build.sh --component llama
  ./build.sh --component vllm

Logs are written to: /opt/ai-tools/logs/builds/<component>_<timestamp>.log
USAGE
  exit 1
}

# ParseArgsCLI - Parse command-line arguments
#
# Arguments: All command-line args ($@)
# Outputs: None
# Returns: 0 on success, exits via ShowUsage on invalid args
# Globals: Sets COMPONENT
ParseArgsCLI() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component)
        COMPONENT="$2"
        shift 2
        ;;
      --node)
        # Ignore --node for backward compatibility
        shift 2
        ;;
      *)
        echo "Error: Unknown argument: $1" >&2
        echo "" >&2
        ShowUsage
        ;;
    esac
  done
  
  # Validate required arguments
  if [[ -z "$COMPONENT" ]]; then
    echo "Error: --component is required" >&2
    echo "" >&2
    ShowUsage
  fi
}

# RunComponentBuild - Execute component-specific build script
#
# Arguments:
#   $1 - component name (string)
# Outputs: Build status to stdout, errors to stderr
# Returns: Exit code from component builder (0=success, non-zero=failure)
# Globals: Reads SCRIPT_DIR, BUILD_LOGS
RunComponentBuild() {
  local component="$1"        # Component name to build
  local timestamp=""         # Current timestamp for log naming
  local log_file=""          # Full path to log file
  local exit_code=0          # Exit code from builder script
  
  timestamp=$(date +%Y%m%d_%H%M%S)
  log_file="$BUILD_LOGS/${component}_${timestamp}.log"
  
  # Ensure log directory exists
  mkdir -p "$BUILD_LOGS"
  
  echo "[build.sh] Starting ${component} build at $(date)" >&2
  echo "[build.sh] Log file: ${log_file}" >&2

  # Dispatch to appropriate component builder
  case "$component" in
    vllm)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_vllm.sh" >&2
      "$SCRIPT_DIR/build_vllm.sh" > "$log_file" 2>&1
      ;;
    llama)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_llamacpp.sh" >&2
      "$SCRIPT_DIR/build_llamacpp.sh" > "$log_file" 2>&1
      ;;
    kokoro)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_kokoro.sh" >&2
      "$SCRIPT_DIR/build_kokoro.sh" > "$log_file" 2>&1
      ;;
    whisper)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_whisper.sh" >&2
      "$SCRIPT_DIR/build_whisper.sh" > "$log_file" 2>&1
      ;;
    dia)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_dia.sh" >&2
      "$SCRIPT_DIR/build_dia.sh" > "$log_file" 2>&1
      ;;
    comfyui)
      echo "[build.sh] Calling: $SCRIPT_DIR/build_comfyui.sh" >&2
      "$SCRIPT_DIR/build_comfyui.sh" > "$log_file" 2>&1
      ;;
    *)
      echo "[build.sh] ERROR: Invalid component: $component" >&2
      ShowUsage
      ;;
  esac
  
  exit_code=$?
  
  # Report results
  if [[ $exit_code -eq 0 ]]; then
    echo "✓ $component build completed successfully"
    echo "  Log: $log_file"
  else
    echo "✗ $component build failed (exit code: $exit_code)" >&2
    echo "  Log: $log_file" >&2
    echo "" >&2
    echo "Last 20 lines of log:" >&2
    tail -20 "$log_file" >&2
  fi
  
  return $exit_code
}

# CoreExec - Main execution function
#
# Arguments: All command-line args ($@)
# Outputs: Build results to stdout
# Returns: Exit code from RunComponentBuild
# Globals: Uses COMPONENT (set by ParseArgsCLI)
CoreExec() {
  ParseArgsCLI "$@"
  RunComponentBuild "$COMPONENT"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
