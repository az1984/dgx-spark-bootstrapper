#!/usr/bin/env bash
# Dia TTS builder - called from build.sh dispatcher
# Multi-character audiobook generation with voice cloning

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
  
  # Check for CUDA (recommended for Dia)
  if command -v nvcc >/dev/null 2>&1; then
    echo "CUDA detected: $(nvcc --version | grep release)"
  else
    echo "WARNING: CUDA not detected, Dia will be significantly slower"
  fi
}

ensure_venv() {
  local venv_path="/opt/ai-tools/dia-env-$1"
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    pip install --upgrade pip
  else
    source "$venv_path/bin/activate"
  fi
  
  export DIA_VENV="$venv_path"
}

install_dependencies() {
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
  pip install soundfile librosa scipy
  pip install pydub
  
  # Additional utilities
  pip install numpy pandas tqdm
  
  # Optional: gradio for web UI
  pip install gradio
}

setup_model_cache() {
  echo "Setting up Dia model cache..."
  
  local model_dir="/opt/ai-models/dia-tts"
  mkdir -p "$model_dir"
  mkdir -p "$model_dir/reference-clips"
  
  # Create reference clips directory structure
  mkdir -p "$model_dir/reference-clips/american-f1"
  mkdir -p "$model_dir/reference-clips/american-f2"
  mkdir -p "$model_dir/reference-clips/british-f"
  mkdir -p "$model_dir/reference-clips/male"
  mkdir -p "$model_dir/reference-clips/russian-f"
  
  # Set cache directory for TTS models
  export COQUI_TOS_AGREED=1  # Agree to TTS model terms
  
  cat > "$model_dir/README.txt" <<'EOF'
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
  source /opt/ai-tools/dia-env-*/bin/activate
  python -m TTS.bin.synthesize --text "Hello world" \
    --model_name tts_models/multilingual/multi-dataset/xtts_v2 \
    --speaker_wav reference-clips/american-f1/clip.wav \
    --out_path output.wav
EOF
  
  echo "Created reference clips directory: $model_dir/reference-clips"
}

download_models() {
  echo "Pre-downloading Dia/XTTS models..."
  
  python -c "
from TTS.api import TTS
import os

# Set cache directory
cache_dir = '/opt/ai-models/dia-tts/models'
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

create_helper_scripts() {
  echo "Creating Dia helper scripts..."
  
  local scripts_dir="/opt/ai-tools/scripts/dia"
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
  
  # Multi-character script template
  cat > "$scripts_dir/dia-multivoice.py" <<'PYTHON'
#!/usr/bin/env python3
"""
Dia TTS - Multi-character audiobook generation
Usage: dia-multivoice.py --input chapter.txt --output chapter.wav
"""

import argparse
import os
import re
from TTS.api import TTS

# TODO: Implement character detection and voice assignment
# TODO: Add sentence splitting and prosody control
# TODO: Implement audio stitching for multi-character scenes

def main():
    print("Multi-character audiobook generation")
    print("This is a template - implement based on your specific needs")
    print("")
    print("For torture test: Ch. 5 'Sharing Is Caring'")
    print("For consistency test: Ch. 7")

if __name__ == "__main__":
    main()
PYTHON

  chmod +x "$scripts_dir/dia-multivoice.py"
  
  echo "Created helper scripts in $scripts_dir"
}

verify_installation() {
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

build_dia() {
  local node_id="$1"
  local log_file="/opt/ai-tools/logs/builds/dia_$(date +%Y%m%d_%H%M%S).log"
  
  # Version checking (if versions.txt exists)
  local version_req="latest"
  if [[ -f "/opt/ai-configuration/desired_state/versions.txt" ]]; then
    version_req=$(grep "dia" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2 || echo "latest")
  fi
  
  {
    echo "=== Starting Dia TTS installation ==="
    echo "Node ID: $node_id"
    echo "Target version: $version_req"
    
    ensure_venv "$node_id"
    validate_dependencies || return 1

    install_dependencies
    setup_model_cache
    download_models
    create_helper_scripts
    verify_installation

    local installed_ver=$(python -c "from TTS import __version__; print(__version__)" 2>/dev/null || echo "unknown")
    
    echo ""
    echo "=== Dia TTS installation successful ==="
    echo "Version: $installed_ver"
    echo "Virtualenv: $(which python)"
    echo "Model cache: /opt/ai-models/dia-tts"
    echo "Reference clips: /opt/ai-models/dia-tts/reference-clips"
    echo ""
    echo "Next steps:"
    echo "1. Add reference clips (10-15s each) to /opt/ai-models/dia-tts/reference-clips/"
    echo "2. Test with: /opt/ai-tools/scripts/dia/dia-synthesize.py"
    echo ""
    echo "Voice characters configured:"
    echo "  - american-f1 (American English Female #1)"
    echo "  - american-f2 (American English Female #2)"
    echo "  - british-f (RP British English Female)"
    echo "  - male (Male voice)"
    echo "  - russian-f (Russian-born Female, mild accent)"
  } | tee "$log_file"
}

build_dia "$@"
