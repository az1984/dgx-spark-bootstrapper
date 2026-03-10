#!/usr/bin/env bash
# Unified build dispatcher with standardized path handling
#
# Coordinates building AI components across DGX Spark nodes by dispatching
# to individual component builders and managing build logs.

set -euo pipefail

source "$(dirname "$0")/common_paths.sh"

# ============================================================================
# Global Variables
# ============================================================================

COMPONENT=""        # Component name to build (vllm|llama|kokoro|whisper|dia|comfyui)
NODE_ID=""          # Target node ID for the build

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
Usage: build.sh --component <name> --node <id>

Arguments:
  --component <name>    Component to build
                        Options: vllm, llama, kokoro, whisper, dia, comfyui
  --node <id>          Node ID (integer)

Examples:
  ./build.sh --component llama --node 4
  ./build.sh --component vllm --node 1

Logs are written to: /opt/ai-tools/logs/builds/<component>_<timestamp>.log
USAGE
  exit 1
}

# ParseArgsCLI - Parse command-line arguments
#
# Arguments: All command-line args ($@)
# Outputs: None
# Returns: 0 on success, exits via ShowUsage on invalid args
# Globals: Sets COMPONENT and NODE_ID
ParseArgsCLI() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component)
        COMPONENT="$2"
        shift 2
        ;;
      --node)
        NODE_ID="$2"
        shift 2
        ;;
      *)
        echo "Error: Unknown argument: $1"
        echo ""
        ShowUsage
        ;;
    esac
  done
  
  # Validate required arguments
  if [[ -z "$COMPONENT" || -z "$NODE_ID" ]]; then
    echo "Error: Both --component and --node are required"
    echo ""
    ShowUsage
  fi
}

# RunComponentBuild - Execute component-specific build script
#
# Arguments:
#   $1 - component name (string)
#   $2 - node ID (integer)
# Outputs: Build status to stdout, errors to stderr
# Returns: Exit code from component builder (0=success, non-zero=failure)
# Globals: Reads SCRIPT_DIR, BUILD_LOGS
RunComponentBuild() {
  local component="$1"        # Component name to build
  local node="$2"            # Target node ID
  local timestamp=""         # Current timestamp for log naming
  local log_file=""          # Full path to log file
  local exit_code=0          # Exit code from builder script
  
  timestamp=$(date +%Y%m%d_%H%M%S)
  log_file="$BUILD_LOGS/${component}_${timestamp}.log"
  
  # Ensure log directory exists
  mkdir -p "$BUILD_LOGS"

  # Dispatch to appropriate component builder
  case "$component" in
    vllm)
      "$SCRIPT_DIR/build_vllm.sh" "$node" > "$log_file" 2>&1
      ;;
    llama)
      "$SCRIPT_DIR/build_llamacpp.sh" --node "$node" > "$log_file" 2>&1
      ;;
    kokoro)
      "$SCRIPT_DIR/build_kokoro.sh" "$node" > "$log_file" 2>&1
      ;;
    whisper)
      "$SCRIPT_DIR/build_whisper.sh" "$node" > "$log_file" 2>&1
      ;;
    dia)
      "$SCRIPT_DIR/build_dia.sh" "$node" > "$log_file" 2>&1
      ;;
    comfyui)
      "$SCRIPT_DIR/build_comfyui.sh" "$node" > "$log_file" 2>&1
      ;;
    *)
      echo "Error: Invalid component: $component"
      ShowUsage
      ;;
  esac
  
  exit_code=$?
  
  # Report results
  if [[ $exit_code -eq 0 ]]; then
    echo "✓ $component build completed successfully"
    echo "  Log: $log_file"
  else
    echo "✗ $component build failed (exit code: $exit_code)"
    echo "  Log: $log_file"
    echo ""
    echo "Last 20 lines of log:"
    tail -20 "$log_file"
  fi
  
  return $exit_code
}

# CoreExec - Main execution function
#
# Arguments: All command-line args ($@)
# Outputs: Build results to stdout
# Returns: Exit code from RunComponentBuild
# Globals: Uses COMPONENT and NODE_ID (set by ParseArgsCLI)
CoreExec() {
  ParseArgsCLI "$@"
  RunComponentBuild "$COMPONENT" "$NODE_ID"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
