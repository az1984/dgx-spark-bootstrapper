#!/usr/bin/env bash
# vLLM builder - Component builder for vLLM inference engine
#
# Installs vLLM from source in a virtual environment with version validation.
# Called by build.sh dispatcher.

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

NODE_ID=""          # Target node ID for this build
VENV_PATH=""        # Path to virtual environment
SRC_PATH=""         # Path to vLLM source directory
VERSION_REQ=""      # Required version from versions.txt

# ============================================================================
# Functions
# ============================================================================

# ValidateDependencies - Check for required system tools
#
# Arguments: None
# Outputs: Status messages to stdout, errors to stderr
# Returns: 0 if all dependencies present, 1 if any missing
# Globals: None
ValidateDependencies() {
  local required_tools=(git python3 pip)  # Required system commands
  local tool=""                           # Current tool being checked
  
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      echo "Missing dependency: $tool"
      return 1
    fi
  done
  
  return 0
}

# EnsureVenv - Create or activate virtual environment
#
# Arguments:
#   $1 - node ID (integer)
# Outputs: Status messages to stdout
# Returns: 0 (always succeeds, exits on venv creation failure)
# Globals: Sets VENV_PATH
EnsureVenv() {
  local node_id="$1"  # Node ID for venv naming
  
  VENV_PATH="/opt/ai-tools/vllm-env-${node_id}"
  
  if [[ ! -d "$VENV_PATH" ]]; then
    echo "Creating virtual environment: $VENV_PATH"
    python3 -m venv "$VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip
  else
    echo "Using existing virtual environment: $VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
  fi
}

# CloneOrUpdateSource - Clone vLLM repo or update existing clone
#
# Arguments: None
# Outputs: Git clone/pull progress to stdout
# Returns: 0 on success, non-zero on git failure
# Globals: Sets SRC_PATH
CloneOrUpdateSource() {
  SRC_PATH="/opt/ai-tools/src/vllm"
  
  if [[ -d "$SRC_PATH/.git" ]]; then
    echo "Updating existing vLLM repository: $SRC_PATH"
    cd "$SRC_PATH"
    git pull
  else
    echo "Cloning vLLM repository: $SRC_PATH"
    mkdir -p "$(dirname "$SRC_PATH")"
    git clone https://github.com/vllm-project/vllm.git "$SRC_PATH"
    cd "$SRC_PATH"
  fi
}

# InstallDependencies - Install vLLM from source
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: Reads SRC_PATH (assumes venv is activated and CWD is SRC_PATH)
InstallDependencies() {
  echo "Installing vLLM dependencies from requirements.txt..."
  pip install -r requirements.txt
  
  echo "Installing vLLM from source..."
  pip install --no-build-isolation .
}

# LoadVersionRequirement - Read required version from versions.txt
#
# Arguments: None
# Outputs: None
# Returns: 0 (always succeeds, sets VERSION_REQ to "latest" if file missing)
# Globals: Sets VERSION_REQ
LoadVersionRequirement() {
  local versions_file="/opt/ai-configuration/desired_state/versions.txt"  # Version spec file
  
  VERSION_REQ="latest"
  
  if [[ -f "$versions_file" ]]; then
    VERSION_REQ=$(grep "vllm" "$versions_file" | cut -d'=' -f2 || echo "latest")
  fi
}

# ValidateInstalledVersion - Check installed version meets requirements
#
# Arguments: None
# Outputs: Version info to stdout, errors to stderr
# Returns: 0 if version valid, 1 if mismatch
# Globals: Reads VERSION_REQ
ValidateInstalledVersion() {
  local installed_ver=""  # Currently installed version
  
  installed_ver=$(python -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "0.0.0")
  
  echo "Installed version: $installed_ver"
  echo "Required version: $VERSION_REQ"
  
  if [[ "$VERSION_REQ" == "latest" ]]; then
    echo "No version requirement specified, accepting: $installed_ver"
    return 0
  fi
  
  if ! ValidateVersion "$installed_ver" "$VERSION_REQ"; then
    echo "ERROR: Version mismatch (installed $installed_ver, required $VERSION_REQ)"
    return 1
  fi
  
  return 0
}

# BuildVLLM - Main build orchestration function
#
# Arguments:
#   $1 - node ID (integer)
# Outputs: Build log to stdout (captured by dispatcher)
# Returns: 0 on success, 1 on failure
# Globals: Uses NODE_ID, VENV_PATH, SRC_PATH, VERSION_REQ
BuildVLLM() {
  local node_id="$1"          # Node ID for this build
  local log_file=""           # Log file path for this build
  
  NODE_ID="$node_id"
  log_file="/opt/ai-tools/logs/builds/vllm_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting vLLM installation ==="
    echo "Node ID: $NODE_ID"
    
    LoadVersionRequirement
    echo "Target version: $VERSION_REQ"
    
    EnsureVenv "$NODE_ID"
    ValidateDependencies || return 1
    CloneOrUpdateSource
    InstallDependencies
    ValidateInstalledVersion || return 1
    
    echo ""
    echo "=== vLLM installation successful ==="
    echo "Source: $SRC_PATH"
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: All CLI args ($@)
# Outputs: Delegates to BuildVLLM
# Returns: Exit code from BuildVLLM
# Globals: None
CoreExec() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: build_vllm.sh <node_id>"
    exit 1
  fi
  
  BuildVLLM "$@"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
