#!/usr/bin/env bash
# Dia TTS builder - Component builder for multi-character audiobook TTS
#
# Installs Coqui TTS with XTTS v2 for voice cloning. Supports multiple
# character voices for audiobook narration. Called by build.sh dispatcher.

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

VENV_PATH=""        # Path to virtual environment
MODEL_DIR=""        # Path to model cache directory
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
  
  # Check for CUDA (recommended for Dia)
  if command -v nvcc >/dev/null 2>&1; then
    echo "CUDA detected: $(nvcc --version | grep release)"
  else
    echo "WARNING: CUDA not detected, Dia will be significantly slower"
  fi
  
  return 0
}

# EnsureVenv - Create or activate virtual environment
#
# Arguments: None
# Outputs: Status messages to stdout
# Returns: 0 (always succeeds, exits on venv creation failure)
# Globals: Sets VENV_PATH
EnsureVenv() {
  local python_cmd=""          # Python command to use
  local python_version=""      # Python version string
  local py_major_minor=""      # Major.minor version
  
  VENV_PATH="/opt/ai-tools/dia-env"
  
  # Coqui TTS requires Python <3.12 (incompatible with 3.12+)
  # Try to find suitable Python version
  
  # First, try Python 3.11 (ideal for Coqui TTS)
  if command -v python3.11 >/dev/null 2>&1; then
    python_cmd="python3.11"
    echo "Using Python 3.11 for Dia TTS: $(python3.11 --version)"
  
  # Second, try pyenv-installed 3.11
  elif [[ -x "$HOME/.pyenv/versions/3.11.8/bin/python" ]]; then
    python_cmd="$HOME/.pyenv/versions/3.11.8/bin/python"
    echo "Using Python 3.11 via pyenv for Dia TTS"
  
  # Third, check if system python3 is compatible
  elif command -v python3 >/dev/null 2>&1; then
    python_version=$(python3 --version 2>&1 | awk '{print $2}')
    py_major_minor=$(echo "${python_version}" | cut -d'.' -f1-2)
    
    echo "Detected system Python version: ${python_version}"
    
    # Check if compatible (3.9, 3.10, or 3.11)
    if [[ "${py_major_minor}" == "3.9" ]] || \
       [[ "${py_major_minor}" == "3.10" ]] || \
       [[ "${py_major_minor}" == "3.11" ]]; then
      python_cmd="python3"
      echo "System Python ${python_version} is compatible with Coqui TTS"
    else
      echo "ERROR: Coqui TTS does not support Python ${py_major_minor}"
      echo ""
      echo "Coqui TTS requires Python 3.9, 3.10, or 3.11"
      echo "System has Python ${python_version} which is incompatible"
      echo ""
      echo "Install Python 3.11 with:"
      echo "  sudo add-apt-repository ppa:deadsnakes/ppa"
      echo "  sudo apt update"
      echo "  sudo apt install python3.11 python3.11-venv python3.11-dev"
      echo ""
      echo "Then re-run this script - it will auto-detect python3.11"
      echo ""
      return 1
    fi
  else
    echo "ERROR: No Python installation found"
    return 1
  fi
  
  # Check for valid venv (must have bin/activate)
  if [[ ! -f "$VENV_PATH/bin/activate" ]]; then
    echo "Creating virtual environment with ${python_cmd}: $VENV_PATH"
    
    # Only remove directory if it's non-empty and broken
    if [[ -d "$VENV_PATH" ]] && [[ -n "$(ls -A "$VENV_PATH" 2>/dev/null)" ]]; then
      echo "Removing broken venv directory: $VENV_PATH"
      rm -rf "$VENV_PATH"
    fi
    
    "${python_cmd}" -m venv "$VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip
  else
    echo "Using existing virtual environment: $VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
  fi
  
  echo "Active Python in venv: $(python --version)"
}

# InstallDependencies - Install Dia TTS and dependencies
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: None (assumes venv is activated)
InstallDependencies() {
  echo "Installing Dia TTS dependencies..."
  
  # Install PyTorch with CUDA support
  if command -v nvcc >/dev/null 2>&1; then
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
  else
    pip install torch torchvision torchaudio
  fi
  
  # Core TTS dependencies
  pip install TTS  # Coqui TTS (includes XTTS for voice cloning)
  
  # Audio processing
  pip install soundfile librosa scipy pydub
  
  # Additional utilities
  pip install numpy pandas tqdm gradio
}

# SetupModelCache - Create model and reference clips directories
#
# Arguments: None
# Outputs: Directory creation messages to stdout
# Returns: 0 (always succeeds)
# Globals: Sets MODEL_DIR
SetupModelCache() {
  echo "Setting up Dia model cache..."
  
  MODEL_DIR="/opt/ai-models/dia-tts"
  mkdir -p "$MODEL_DIR"
  mkdir -p "$MODEL_DIR/reference-clips"
  
  # Create reference clips directory structure
  local voice_dirs=(american-f1 american-f2 british-f male russian-f)  # Voice character directories
  local dir=""                                                          # Current directory being created
  
  for dir in "${voice_dirs[@]}"; do
    mkdir -p "$MODEL_DIR/reference-clips/$dir"
  done
  
  # Set cache directory for TTS models
  export COQUI_TOS_AGREED=1  # Agree to TTS model terms
  
  cat > "$MODEL_DIR/README.txt" <<'EOF'
Dia TTS Reference Clips Directory
==================================

Place 10-15 second audio clips for each character voice here:

american-f1/    - American English Female #1
american-f2/    - American English Female #2 (distinct from F1)
british-f/      - RP British English Female
male/           - Male voice (any accent)
russian-f/      - Russian-born Female (mild accent)

Requirements:
- Format: WAV, MP3, or FLAC
- Duration: 10-15 seconds of clean speech
- Register: Conversational (not careful reading-aloud)
- Quality: Clear audio, minimal background noise

Test chapters:
- Ch. 5 "Sharing Is Caring" - 3F + 1M dinner scene (torture test)
- Ch. 7 - Two mains, emotional peak (consistency check)

Usage:
  source /opt/ai-tools/dia-env/bin/activate
  python -m TTS.bin.synthesize --text "Hello world" \
    --model_name tts_models/multilingual/multi-dataset/xtts_v2 \
    --speaker_wav reference-clips/american-f1/clip.wav \
    --out_path output.wav
EOF
  
  echo "Created reference clips directory: $MODEL_DIR/reference-clips"
}

# DownloadModels - Pre-download XTTS v2 models
#
# Arguments: None
# Outputs: Download progress to stdout
# Returns: 0 (always succeeds, warnings on download failures)
# Globals: Reads MODEL_DIR
DownloadModels() {
  echo "Pre-downloading Dia/XTTS models..."
  
  python -c "
from TTS.api import TTS
import os

# Set cache directory
cache_dir = '$MODEL_DIR/models'
os.makedirs(cache_dir, exist_ok=True)
os.environ['TTS_HOME'] = cache_dir

try:
    # Download XTTS v2 (best for voice cloning)
    print('Downloading XTTS v2 model...')
    tts = TTS('tts_models/multilingual/multi-dataset/xtts_v2')
    print('✓ XTTS v2 downloaded')
    
    # List available models
    print('')
    print('Available TTS models:')
    print(TTS().list_models())
except Exception as e:
    print(f'⚠ Model download failed: {e}')
    print('Models will be downloaded on first use')
"
}

# CreateHelperScripts - Generate synthesis helper scripts
#
# Arguments: None
# Outputs: Script creation messages to stdout
# Returns: 0 (always succeeds)
# Globals: Reads MODEL_DIR
CreateHelperScripts() {
  echo "Creating Dia helper scripts..."
  
  local scripts_dir="/opt/ai-tools/scripts/dia"  # Helper scripts directory
  mkdir -p "$scripts_dir"
  
  # Simple synthesis script
  cat > "$scripts_dir/dia-synthesize.py" <<'PYTHON'
#!/usr/bin/env python3
"""
Dia TTS - Simple synthesis script
Usage: dia-synthesize.py --text "Hello" --voice american-f1 --output out.wav
"""

import argparse
import os
from TTS.api import TTS

REFERENCE_DIR = "/opt/ai-models/dia-tts/reference-clips"
VOICE_MAP = {
    "american-f1": f"{REFERENCE_DIR}/american-f1",
    "american-f2": f"{REFERENCE_DIR}/american-f2",
    "british-f": f"{REFERENCE_DIR}/british-f",
    "male": f"{REFERENCE_DIR}/male",
    "russian-f": f"{REFERENCE_DIR}/russian-f",
}

def main():
    parser = argparse.ArgumentParser(description="Dia TTS synthesis")
    parser.add_argument("--text", required=True, help="Text to synthesize")
    parser.add_argument("--voice", required=True, choices=VOICE_MAP.keys(), 
                       help="Voice character to use")
    parser.add_argument("--output", default="output.wav", help="Output file")
    parser.add_argument("--language", default="en", help="Language code")
    
    args = parser.parse_args()
    
    # Find reference clip
    voice_dir = VOICE_MAP[args.voice]
    if not os.path.exists(voice_dir):
        print(f"ERROR: Voice directory not found: {voice_dir}")
        print(f"Please add a reference clip to {voice_dir}/")
        return 1
    
    # Get first audio file in directory
    clips = [f for f in os.listdir(voice_dir) 
             if f.endswith(('.wav', '.mp3', '.flac'))]
    
    if not clips:
        print(f"ERROR: No audio clips found in {voice_dir}")
        print("Please add a 10-15s reference clip")
        return 1
    
    reference_clip = os.path.join(voice_dir, clips[0])
    
    # Initialize TTS
    print(f"Loading XTTS v2 model...")
    tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
    
    # Synthesize
    print(f"Synthesizing with voice: {args.voice}")
    print(f"Reference clip: {reference_clip}")
    
    tts.tts_to_file(
        text=args.text,
        speaker_wav=reference_clip,
        language=args.language,
        file_path=args.output
    )
    
    print(f"✓ Output written to {args.output}")

if __name__ == "__main__":
    main()
PYTHON

  chmod +x "$scripts_dir/dia-synthesize.py"
  
  echo "Created helper scripts in $scripts_dir"
}

# VerifyInstallation - Test Dia TTS installation
#
# Arguments: None
# Outputs: Verification results to stdout
# Returns: 0 (always succeeds, warnings on verification failures)
# Globals: None
VerifyInstallation() {
  echo "Verifying Dia TTS installation..."
  
  python -c "
from TTS.api import TTS
import torch
import sys

try:
    print('✓ TTS import successful')
    print(f'✓ PyTorch version: {torch.__version__}')
    print(f'✓ CUDA available: {torch.cuda.is_available()}')
    
    # Try loading XTTS (may take a moment)
    tts = TTS('tts_models/multilingual/multi-dataset/xtts_v2')
    print('✓ XTTS v2 model loaded')
    
except Exception as e:
    print(f'⚠ Verification warning: {e}', file=sys.stderr)
    print('Note: Models will download on first use')
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
    VERSION_REQ=$(grep "dia" "$versions_file" | cut -d'=' -f2 || echo "latest")
  fi
}

# BuildDia - Main build orchestration function
#
# Arguments: None
# Outputs: Build log to stdout
# Returns: 0 on success, 1 on failure
# Globals: Uses VENV_PATH, MODEL_DIR, VERSION_REQ
BuildDia() {
  local log_file=""           # Log file path for this build
  local installed_ver=""      # Installed TTS version
  
  log_file="/opt/ai-tools/logs/builds/dia_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting Dia TTS installation ==="
    
    LoadVersionRequirement
    echo "Target version: $VERSION_REQ"
    
    EnsureVenv
    ValidateDependencies || return 1
    InstallDependencies
    SetupModelCache
    DownloadModels
    CreateHelperScripts
    VerifyInstallation
    
    installed_ver=$(python -c "from TTS import __version__; print(__version__)" 2>/dev/null || echo "unknown")
    
    echo ""
    echo "=== Dia TTS installation successful ==="
    echo "Version: $installed_ver"
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
    echo "Model cache: $MODEL_DIR"
    echo "Reference clips: $MODEL_DIR/reference-clips"
    echo ""
    echo "Next steps:"
    echo "1. Add reference clips (10-15s each) to $MODEL_DIR/reference-clips/"
    echo "2. Test with: /opt/ai-tools/scripts/dia/dia-synthesize.py"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: None
# Outputs: Delegates to BuildDia
# Returns: Exit code from BuildDia
# Globals: None
CoreExec() {
  BuildDia
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec
