#!/usr/bin/env bash
# Kokoro TTS builder - Component builder for basic text-to-speech
#
# Installs Kokoro TTS in a virtual environment with version validation.
# Called by build.sh dispatcher.

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

VENV_PATH=""        # Path to virtual environment
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
# Arguments: None
# Outputs: Status messages to stdout
# Returns: 0 (always succeeds, exits on venv creation failure)
# Globals: Sets VENV_PATH
EnsureVenv() {
  VENV_PATH="/opt/ai-tools/kokoro-env"
  
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

# InstallDependencies - Install Kokoro TTS and dependencies
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: None (assumes venv is activated)
InstallDependencies() {
  echo "Installing Kokoro TTS dependencies..."
  
  # Install PyTorch first
  pip install --upgrade torch
  
  # Install Kokoro from PyPI (official hexgrad package)
  # Note: This is the REAL Kokoro (Apache-licensed, 82M params)
  # NOT kokoro-ai (which is a different/private project)
  pip install kokoro soundfile
  
  # Install espeak-ng for phoneme fallback (system package, may already be installed)
  echo "Note: Kokoro works best with espeak-ng installed system-wide"
  echo "Install with: sudo apt-get install espeak-ng"
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
    VERSION_REQ=$(grep "kokoro" "$versions_file" | cut -d'=' -f2 || echo "latest")
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
  
  installed_ver=$(python -c "from kokoro_tts import __version__; print(__version__)" 2>/dev/null || echo "0.0.0")
  
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

# BuildKokoro - Main build orchestration function
#
# Arguments: None
# Outputs: Build log to stdout
# Returns: 0 on success, 1 on failure
# Globals: Uses VENV_PATH, VERSION_REQ
BuildKokoro() {
  local log_file=""           # Log file path for this build
  
  log_file="/opt/ai-tools/logs/builds/kokoro_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting Kokoro TTS installation ==="
    
    LoadVersionRequirement
    echo "Target version: $VERSION_REQ"
    
    EnsureVenv
    ValidateDependencies || return 1
    InstallDependencies
    ValidateInstalledVersion || return 1
    
    echo ""
    echo "=== Kokoro TTS installation successful ==="
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: None
# Outputs: Delegates to BuildKokoro
# Returns: Exit code from BuildKokoro
# Globals: None
CoreExec() {
  BuildKokoro
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec
