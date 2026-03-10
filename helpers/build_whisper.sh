#!/usr/bin/env bash
# Whisper ASR builder - called from build.sh dispatcher

set -euo pipefail

source "$(dirname "$0")/semver.sh"

validate_dependencies() {
  local required_tools=(git python3 pip ffmpeg)
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
}

ensure_venv() {
  local venv_path="/opt/ai-tools/whisper-env-$1"
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    pip install --upgrade pip
  else
    source "$venv_path/bin/activate"
  fi
  
  export WHISPER_VENV="$venv_path"
}

install_dependencies() {
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

download_models() {
  echo "Pre-downloading Whisper models..."
  
  # Download common models to avoid first-run delays
  # Models: tiny, base, small, medium, large-v3
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

verify_installation() {
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

build_whisper() {
  local node_id="$1"
  local log_file="/opt/ai-tools/logs/builds/whisper_$(date +%Y%m%d_%H%M%S).log"
  
  # Version checking (if versions.txt exists)
  local version_req="latest"
  if [[ -f "/opt/ai-configuration/desired_state/versions.txt" ]]; then
    version_req=$(grep "whisper" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2 || echo "latest")
  fi
  
  {
    echo "=== Starting Whisper ASR installation ==="
    echo "Node ID: $node_id"
    echo "Target version: $version_req"
    
    ensure_venv "$node_id"
    validate_dependencies || return 1

    install_dependencies
    download_models
    verify_installation

    local installed_ver=$(python -c "import whisper; print(whisper.__version__)" 2>/dev/null || echo "unknown")
    
    echo "=== Whisper ASR installation successful ==="
    echo "Version: $installed_ver"
    echo "Virtualenv: $(which python)"
    echo "Model cache: /opt/ai-models/whisper"
    echo ""
    echo "Usage example:"
    echo "  source $WHISPER_VENV/bin/activate"
    echo "  whisper audio.mp3 --model medium --language en"
  } | tee "$log_file"
}

build_whisper "$@"
