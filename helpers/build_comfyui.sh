#!/usr/bin/env bash
# ComfyUI builder - called from build.sh dispatcher

set -euo pipefail

source "$(dirname "$0")/semver.sh"

validate_dependencies() {
  local required_tools=(git python3 pip)
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      echo "Missing dependency: $tool"
      return 1
    fi
  done
  
  # Check for CUDA
  if command -v nvcc >/dev/null 2>&1; then
    echo "CUDA detected: $(nvcc --version | grep release)"
  else
    echo "WARNING: CUDA not detected, ComfyUI will be very slow"
  fi
}

ensure_venv() {
  local venv_path="/opt/ai-tools/comfyui-env-$1"
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    pip install --upgrade pip
  else
    source "$venv_path/bin/activate"
  fi
  
  export COMFYUI_VENV="$venv_path"
}

clone_or_update_comfyui() {
  local src_dir="/opt/ai-tools/src/ComfyUI"
  
  if [[ -d "$src_dir/.git" ]]; then
    echo "Updating existing ComfyUI repository..."
    cd "$src_dir"
    git pull --ff-only
  else
    echo "Cloning ComfyUI repository..."
    mkdir -p "$(dirname "$src_dir")"
    git clone https://github.com/comfyanonymous/ComfyUI "$src_dir"
    cd "$src_dir"
  fi
  
  export COMFYUI_SRC="$src_dir"
}

install_dependencies() {
  echo "Installing ComfyUI dependencies..."
  
  cd "$COMFYUI_SRC"
  
  # Install PyTorch with CUDA support
  if command -v nvcc >/dev/null 2>&1; then
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
  else
    pip install torch torchvision torchaudio
  fi
  
  # Install ComfyUI requirements
  if [[ -f requirements.txt ]]; then
    pip install -r requirements.txt
  else
    echo "WARNING: requirements.txt not found"
  fi
  
  # Optional but recommended dependencies
  pip install opencv-python pillow numpy
}

setup_model_directories() {
  echo "Setting up ComfyUI model directories..."
  
  local model_base="/opt/ai-models/comfyui"
  
  # Create model directory structure
  mkdir -p "$model_base/checkpoints"     # Stable Diffusion checkpoints
  mkdir -p "$model_base/vae"             # VAE models
  mkdir -p "$model_base/loras"           # LoRA models
  mkdir -p "$model_base/embeddings"      # Textual inversions
  mkdir -p "$model_base/controlnet"      # ControlNet models
  mkdir -p "$model_base/clip"            # CLIP models
  mkdir -p "$model_base/upscale_models"  # Upscalers
  
  # Create symlinks in ComfyUI directory
  cd "$COMFYUI_SRC"
  
  if [[ ! -d "models" ]]; then
    mkdir -p models
  fi
  
  # Symlink model directories
  for dir in checkpoints vae loras embeddings controlnet clip upscale_models; do
    if [[ ! -L "models/$dir" ]]; then
      ln -sf "$model_base/$dir" "models/$dir"
      echo "  Linked models/$dir → $model_base/$dir"
    fi
  done
  
  cat > "$model_base/README.txt" <<'EOF'
ComfyUI Model Directory
=======================

Place your models in these directories:

checkpoints/     - Stable Diffusion checkpoints (.safetensors or .ckpt)
                   Examples: SD 1.5, SDXL, Flux
vae/            - VAE models (for better image quality)
loras/          - LoRA adaptations
embeddings/     - Textual inversion embeddings
controlnet/     - ControlNet models
clip/           - CLIP vision models
upscale_models/ - Image upscalers (ESRGAN, RealESRGAN, etc.)

Recommended starter models:
1. SD 1.5: https://huggingface.co/runwayml/stable-diffusion-v1-5
2. SDXL: https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0
3. Flux: https://huggingface.co/black-forest-labs/FLUX.1-schnell

Download with:
  cd /opt/ai-models/comfyui/checkpoints
  aria2c -x 16 <huggingface-url>
EOF
  
  echo "Model directories configured at: $model_base"
}

install_custom_nodes() {
  echo "Installing essential custom nodes..."
  
  cd "$COMFYUI_SRC"
  mkdir -p custom_nodes
  cd custom_nodes
  
  # ComfyUI Manager (essential for node management)
  if [[ ! -d "ComfyUI-Manager" ]]; then
    echo "Installing ComfyUI-Manager..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager
  else
    echo "Updating ComfyUI-Manager..."
    cd ComfyUI-Manager && git pull --ff-only && cd ..
  fi
  
  echo "Custom nodes installed"
  echo "Note: Additional nodes can be installed via ComfyUI Manager web interface"
}

create_launch_script() {
  echo "Creating ComfyUI launch script..."
  
  local launch_script="/opt/ai-tools/scripts/launch_comfyui.sh"
  mkdir -p "$(dirname "$launch_script")"
  
  cat > "$launch_script" <<LAUNCH
#!/usr/bin/env bash
# ComfyUI launcher script

set -euo pipefail

# Activate virtual environment
source "$COMFYUI_VENV/bin/activate"

# Set model paths
export COMFYUI_MODEL_DIR="/opt/ai-models/comfyui"

# Launch ComfyUI
cd "$COMFYUI_SRC"

echo "Starting ComfyUI..."
echo "Model directory: \$COMFYUI_MODEL_DIR"
echo "Web UI will be available at: http://localhost:8188"
echo ""

python main.py "\$@"
LAUNCH

  chmod +x "$launch_script"
  echo "Launch script created: $launch_script"
}

verify_installation() {
  echo "Verifying ComfyUI installation..."
  
  cd "$COMFYUI_SRC"
  
  python -c "
import torch
import sys
import os

try:
    print('✓ PyTorch import successful')
    print(f'✓ PyTorch version: {torch.__version__}')
    print(f'✓ CUDA available: {torch.cuda.is_available()}')
    
    # Check for ComfyUI modules
    sys.path.insert(0, '$COMFYUI_SRC')
    import nodes
    print('✓ ComfyUI nodes module loaded')
    
    # Check model directories
    model_base = '/opt/ai-models/comfyui'
    dirs = ['checkpoints', 'vae', 'loras']
    for d in dirs:
        path = os.path.join(model_base, d)
        if os.path.exists(path):
            print(f'✓ Model directory exists: {d}/')
    
except Exception as e:
    print(f'⚠ Verification warning: {e}', file=sys.stderr)
"
}

build_comfyui() {
  local node_id="$1"
  local log_file="/opt/ai-tools/logs/builds/comfyui_$(date +%Y%m%d_%H%M%S).log"
  
  # Version checking (if versions.txt exists)
  local version_req="latest"
  if [[ -f "/opt/ai-configuration/desired_state/versions.txt" ]]; then
    version_req=$(grep "comfyui" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2 || echo "latest")
  fi
  
  {
    echo "=== Starting ComfyUI installation ==="
    echo "Node ID: $node_id"
    echo "Target version: $version_req"
    
    ensure_venv "$node_id"
    validate_dependencies || return 1

    clone_or_update_comfyui
    install_dependencies
    setup_model_directories
    install_custom_nodes
    create_launch_script
    verify_installation

    # Get git commit hash as version
    cd "$COMFYUI_SRC"
    local installed_ver=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    echo ""
    echo "=== ComfyUI installation successful ==="
    echo "Version (git): $installed_ver"
    echo "Source: $COMFYUI_SRC"
    echo "Virtualenv: $(which python)"
    echo "Model directory: /opt/ai-models/comfyui"
    echo ""
    echo "Next steps:"
    echo "1. Download models to /opt/ai-models/comfyui/checkpoints/"
    echo "2. Launch with: /opt/ai-tools/scripts/launch_comfyui.sh"
    echo "3. Access at: http://localhost:8188"
    echo ""
    echo "Recommended starter models:"
    echo "  - Stable Diffusion 1.5"
    echo "  - SDXL Base"
    echo "  - Flux Schnell (fast)"
  } | tee "$log_file"
}

build_comfyui "$@"
