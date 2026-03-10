#!/usr/bin/env bash
# ComfyUI builder - Component builder for Stable Diffusion image generation
#
# Installs ComfyUI with PyTorch, sets up model directories with symlinks,
# and installs ComfyUI-Manager. Called by build.sh dispatcher.

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

NODE_ID=""          # Target node ID for this build
VENV_PATH=""        # Path to virtual environment
SRC_DIR=""          # Path to ComfyUI source directory
MODEL_BASE=""       # Path to model storage base directory
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
  
  # Check for CUDA
  if command -v nvcc >/dev/null 2>&1; then
    echo "CUDA detected: $(nvcc --version | grep release)"
  else
    echo "WARNING: CUDA not detected, ComfyUI will be very slow"
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
  
  VENV_PATH="/opt/ai-tools/comfyui-env-${node_id}"
  
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

# CloneOrUpdateComfyUI - Clone ComfyUI repo or update existing clone
#
# Arguments: None
# Outputs: Git clone/pull progress to stdout
# Returns: 0 on success, non-zero on git failure
# Globals: Sets SRC_DIR
CloneOrUpdateComfyUI() {
  SRC_DIR="/opt/ai-tools/src/ComfyUI"
  
  if [[ -d "$SRC_DIR/.git" ]]; then
    echo "Updating existing ComfyUI repository..."
    cd "$SRC_DIR"
    git pull --ff-only
  else
    echo "Cloning ComfyUI repository..."
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone https://github.com/comfyanonymous/ComfyUI "$SRC_DIR"
    cd "$SRC_DIR"
  fi
}

# InstallDependencies - Install ComfyUI and dependencies
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: Reads SRC_DIR (assumes venv is activated and CWD is SRC_DIR)
InstallDependencies() {
  echo "Installing ComfyUI dependencies..."
  
  cd "$SRC_DIR"
  
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

# SetupModelDirectories - Create model directories and symlinks
#
# Arguments: None
# Outputs: Directory creation and symlink messages to stdout
# Returns: 0 (always succeeds)
# Globals: Sets MODEL_BASE, reads SRC_DIR
SetupModelDirectories() {
  echo "Setting up ComfyUI model directories..."
  
  MODEL_BASE="/opt/ai-models/comfyui"
  
  # Create model directory structure
  local model_dirs=(checkpoints vae loras embeddings controlnet clip upscale_models)  # Model subdirectories
  local dir=""                                                                        # Current directory being created
  
  for dir in "${model_dirs[@]}"; do
    mkdir -p "$MODEL_BASE/$dir"
  done
  
  # Create symlinks in ComfyUI directory
  cd "$SRC_DIR"
  
  if [[ ! -d "models" ]]; then
    mkdir -p models
  fi
  
  # Symlink model directories
  for dir in "${model_dirs[@]}"; do
    if [[ ! -L "models/$dir" ]]; then
      ln -sf "$MODEL_BASE/$dir" "models/$dir"
      echo "  Linked models/$dir → $MODEL_BASE/$dir"
    fi
  done
  
  cat > "$MODEL_BASE/README.txt" <<'EOF'
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
  
  echo "Model directories configured at: $MODEL_BASE"
}

# InstallCustomNodes - Install ComfyUI-Manager and other custom nodes
#
# Arguments: None
# Outputs: Git clone/pull progress to stdout
# Returns: 0 (always succeeds)
# Globals: Reads SRC_DIR
InstallCustomNodes() {
  echo "Installing essential custom nodes..."
  
  cd "$SRC_DIR"
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

# CreateLaunchScript - Generate ComfyUI launcher script
#
# Arguments: None
# Outputs: Script creation messages to stdout
# Returns: 0 (always succeeds)
# Globals: Reads VENV_PATH, SRC_DIR
CreateLaunchScript() {
  echo "Creating ComfyUI launch script..."
  
  local launch_script="/opt/ai-tools/scripts/launch_comfyui.sh"  # Launcher script path
  mkdir -p "$(dirname "$launch_script")"
  
  cat > "$launch_script" <<LAUNCH
#!/usr/bin/env bash
# ComfyUI launcher script

set -euo pipefail

# Activate virtual environment
source "$VENV_PATH/bin/activate"

# Set model paths
export COMFYUI_MODEL_DIR="/opt/ai-models/comfyui"

# Launch ComfyUI
cd "$SRC_DIR"

echo "Starting ComfyUI..."
echo "Model directory: \$COMFYUI_MODEL_DIR"
echo "Web UI will be available at: http://localhost:8188"
echo ""

python main.py "\$@"
LAUNCH

  chmod +x "$launch_script"
  echo "Launch script created: $launch_script"
}

# VerifyInstallation - Test ComfyUI installation
#
# Arguments: None
# Outputs: Verification results to stdout
# Returns: 0 (always succeeds, warnings on verification failures)
# Globals: Reads SRC_DIR, MODEL_BASE
VerifyInstallation() {
  echo "Verifying ComfyUI installation..."
  
  cd "$SRC_DIR"
  
  python -c "
import torch
import sys
import os

try:
    print('✓ PyTorch import successful')
    print(f'✓ PyTorch version: {torch.__version__}')
    print(f'✓ CUDA available: {torch.cuda.is_available()}')
    
    # Check for ComfyUI modules
    sys.path.insert(0, '$SRC_DIR')
    import nodes
    print('✓ ComfyUI nodes module loaded')
    
    # Check model directories
    model_base = '$MODEL_BASE'
    dirs = ['checkpoints', 'vae', 'loras']
    for d in dirs:
        path = os.path.join(model_base, d)
        if os.path.exists(path):
            print(f'✓ Model directory exists: {d}/')
    
except Exception as e:
    print(f'⚠ Verification warning: {e}', file=sys.stderr)
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
    VERSION_REQ=$(grep "comfyui" "$versions_file" | cut -d='=' -f2 || echo "latest")
  fi
}

# BuildComfyUI - Main build orchestration function
#
# Arguments:
#   $1 - node ID (integer)
# Outputs: Build log to stdout (captured by dispatcher)
# Returns: 0 on success, 1 on failure
# Globals: Uses NODE_ID, VENV_PATH, SRC_DIR, MODEL_BASE, VERSION_REQ
BuildComfyUI() {
  local node_id="$1"          # Node ID for this build
  local log_file=""           # Log file path for this build
  local installed_ver=""      # Installed ComfyUI version (git hash)
  
  NODE_ID="$node_id"
  log_file="/opt/ai-tools/logs/builds/comfyui_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting ComfyUI installation ==="
    echo "Node ID: $NODE_ID"
    
    LoadVersionRequirement
    echo "Target version: $VERSION_REQ"
    
    EnsureVenv "$NODE_ID"
    ValidateDependencies || return 1
    CloneOrUpdateComfyUI
    InstallDependencies
    SetupModelDirectories
    InstallCustomNodes
    CreateLaunchScript
    VerifyInstallation
    
    # Get git commit hash as version
    cd "$SRC_DIR"
    installed_ver=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    echo ""
    echo "=== ComfyUI installation successful ==="
    echo "Version (git): $installed_ver"
    echo "Source: $SRC_DIR"
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
    echo "Model directory: $MODEL_BASE"
    echo ""
    echo "Next steps:"
    echo "1. Download models to $MODEL_BASE/checkpoints/"
    echo "2. Launch with: /opt/ai-tools/scripts/launch_comfyui.sh"
    echo "3. Access at: http://localhost:8188"
    echo ""
    echo "Recommended starter models:"
    echo "  - Stable Diffusion 1.5"
    echo "  - SDXL Base"
    echo "  - Flux Schnell (fast)"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: All CLI args ($@)
# Outputs: Delegates to BuildComfyUI
# Returns: Exit code from BuildComfyUI
# Globals: None
CoreExec() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: build_comfyui.sh <node_id>"
    exit 1
  fi
  
  BuildComfyUI "$@"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
