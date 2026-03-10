#!/usr/bin/env bash
# Whisper ASR builder - Component builder for speech-to-text
#
# Installs OpenAI Whisper and faster-whisper in a virtual environment
# with CUDA support when available. Called by build.sh dispatcher.

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

NODE_ID=""          # Target node ID for this build
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
  local required_tools=(git python3 pip ffmpeg)  # Required system commands
  local tool=""                                  # Current tool being checked
  
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      echo "Missing dependency: $tool"
      return 1
    fi
  done
  
  # Check for CUDA if available (optional, falls back to CPU)
  if command -v nvcc >/dev/null 2>&1; then
    echo "CUDA detected: $(nvcc --version | grep release)"
  else
    echo "WARNING: CUDA not detected, Whisper will run on CPU (slower)"
  fi
  
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
  
  VENV_PATH="/opt/ai-tools/whisper-env-${node_id}"
  
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

# InstallDependencies - Install Whisper and dependencies
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: None (assumes venv is activated)
InstallDependencies() {
  echo "Installing Whisper dependencies..."
  
  # Install PyTorch first (CUDA-aware if available)
  if command -v nvcc >/dev/null 2>&1; then
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
  else
    pip install torch torchvision torchaudio
  fi
  
  # Install OpenAI Whisper
  pip install openai-whisper
  
  # Optional: faster-whisper for better performance
  pip install faster-whisper
  
  # Audio processing utilities
  pip install soundfile librosa
}

# DownloadModels - Pre-download common Whisper models
#
# Arguments: None
# Outputs: Download progress to stdout
# Returns: 0 (always succeeds, warnings on download failures)
# Globals: None
DownloadModels() {
  echo "Pre-downloading Whisper models..."
  
  python -c "
import whisper
import os

# Set cache directory
cache_dir = '/opt/ai-models/whisper'
os.makedirs(cache_dir, exist_ok=True)
os.environ['WHISPER_CACHE'] = cache_dir

models = ['base', 'small', 'medium']
for model_name in models:
    print(f'Downloading {model_name}...')
    try:
        whisper.load_model(model_name, download_root=cache_dir)
        print(f'✓ {model_name} downloaded')
    except Exception as e:
        print(f'⚠ Failed to download {model_name}: {e}')
"
}

# VerifyInstallation - Test Whisper installation
#
# Arguments: None
# Outputs: Verification results to stdout
# Returns: 0 on success, 1 on verification failure
# Globals: None
VerifyInstallation() {
  echo "Verifying Whisper installation..."
  
  python -c "
import whisper
import sys

try:
    model = whisper.load_model('base', download_root='/opt/ai-models/whisper')
    print('✓ Whisper import successful')
    print(f'✓ Base model loaded')
    print(f'Available models: {whisper.available_models()}')
except Exception as e:
    print(f'✗ Verification failed: {e}', file=sys.stderr)
    sys.exit(1)
"
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
    VERSION_REQ=$(grep "whisper" "$versions_file" | cut -d='=' -f2 || echo "latest")
  fi
}

# BuildWhisper - Main build orchestration function
#
# Arguments:
#   $1 - node ID (integer)
# Outputs: Build log to stdout (captured by dispatcher)
# Returns: 0 on success, 1 on failure
# Globals: Uses NODE_ID, VENV_PATH, VERSION_REQ
BuildWhisper() {
  local node_id="$1"          # Node ID for this build
  local log_file=""           # Log file path for this build
  local installed_ver=""      # Installed Whisper version
  
  NODE_ID="$node_id"
  log_file="/opt/ai-tools/logs/builds/whisper_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting Whisper ASR installation ==="
    echo "Node ID: $NODE_ID"
    
    LoadVersionRequirement
    echo "Target version: $VERSION_REQ"
    
    EnsureVenv "$NODE_ID"
    ValidateDependencies || return 1
    InstallDependencies
    DownloadModels
    VerifyInstallation
    
    installed_ver=$(python -c "import whisper; print(whisper.__version__)" 2>/dev/null || echo "unknown")
    
    echo ""
    echo "=== Whisper ASR installation successful ==="
    echo "Version: $installed_ver"
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
    echo "Model cache: /opt/ai-models/whisper"
    echo ""
    echo "Usage example:"
    echo "  source $VENV_PATH/bin/activate"
    echo "  whisper audio.mp3 --model medium --language en"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: All CLI args ($@)
# Outputs: Delegates to BuildWhisper
# Returns: Exit code from BuildWhisper
# Globals: None
CoreExec() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: build_whisper.sh <node_id>"
    exit 1
  fi
  
  BuildWhisper "$@"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
