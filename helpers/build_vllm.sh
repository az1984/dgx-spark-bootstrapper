#!/usr/bin/env bash
# vLLM builder - Component builder for vLLM inference engine
#
# Installs vLLM with locked versions from seed file to ensure cluster consistency.
# Called by build.sh dispatcher.
#
# Version locking is critical for vLLM:
# - Ray version must match exactly across cluster nodes
# - PyTorch CUDA version must match installed CUDA toolkit
# - Triton version affects flash attention support
# - sm_120a (GH200/Hopper) requires specific CUDA compiler versions

set -euo pipefail

source "$(dirname "$0")/semver.sh"

# ============================================================================
# Global Variables
# ============================================================================

VENV_PATH=""        # Path to virtual environment
SEED_FILE=""        # Path to version seed file
VERSION_REQ=""      # Required vLLM version from seed

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
  local required_tools=(git python3 pip nvcc)  # Required system commands
  local tool=""                                # Current tool being checked
  local cuda_version=""                        # CUDA compiler version
  
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      echo "Missing dependency: $tool"
      return 1
    fi
  done
  
  # Check CUDA version (vLLM needs CUDA 12.x)
  cuda_version=$(nvcc --version | grep -oP 'release \K[0-9.]+' || echo "unknown")
  echo "CUDA compiler version: $cuda_version"
  
  if [[ ! "$cuda_version" =~ ^12\. ]] && [[ ! "$cuda_version" =~ ^13\. ]]; then
    echo "WARNING: CUDA $cuda_version may not be compatible with vLLM seed versions"
    echo "Expected CUDA 12.x or 13.x"
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
  VENV_PATH="/opt/ai-tools/vllm-env"
  
  # Check for valid venv (must have bin/activate)
  if [[ ! -f "$VENV_PATH/bin/activate" ]]; then
    echo "Creating virtual environment: $VENV_PATH"
    
    # Only remove directory if it's non-empty and broken
    if [[ -d "$VENV_PATH" ]] && [[ -n "$(ls -A "$VENV_PATH" 2>/dev/null)" ]]; then
      echo "Removing broken venv directory: $VENV_PATH"
      rm -rf "$VENV_PATH"
    fi
    
    python3 -m venv "$VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip
  else
    echo "Using existing virtual environment: $VENV_PATH"
    # shellcheck disable=SC1090
    source "$VENV_PATH/bin/activate"
  fi
  
  echo "Python version in venv: $(python --version)"
}

# LoadSeedFile - Read version requirements from seed file
#
# Arguments: None
# Outputs: Seed file path to stdout
# Returns: 0 if found, 1 if missing
# Globals: Sets SEED_FILE, VERSION_REQ
LoadSeedFile() {
  local script_dir=""          # Directory containing this script
  local seed_locations=()      # Possible seed file locations
  local loc=""                 # Current location being checked
  
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  
  # Try multiple locations for seed file
  seed_locations=(
    "${script_dir}/seeds/vllm_env_versions.txt"
    "${script_dir}/../seeds/vllm_env_versions.txt"
    "/opt/ai-tools/seeds/vllm_env_versions.txt"
    "${script_dir}/vllm_env_versions.txt"
  )
  
  for loc in "${seed_locations[@]}"; do
    if [[ -f "$loc" ]]; then
      SEED_FILE="$loc"
      echo "Found seed file: $SEED_FILE"
      
      # Extract vLLM version from seed
      VERSION_REQ=$(grep "^vllm==" "$SEED_FILE" | cut -d'=' -f3 || echo "latest")
      echo "Target vLLM version from seed: $VERSION_REQ"
      
      return 0
    fi
  done
  
  echo "WARNING: No seed file found, will install latest versions"
  echo "Searched locations:"
  for loc in "${seed_locations[@]}"; do
    echo "  - $loc"
  done
  
  VERSION_REQ="latest"
  return 1
}

# InstallFromSeed - Install packages from seed file with exact versions
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: Reads SEED_FILE
InstallFromSeed() {
  local pytorch_index="https://download.pytorch.org/whl/cu129"  # PyTorch CUDA 12.9 index
  
  echo "Installing vLLM from seed file: $SEED_FILE"
  echo ""
  echo "=== Installation Strategy ==="
  echo "1. Install PyTorch with CUDA 12.9 from PyTorch index"
  echo "2. Install Ray (pinned version critical for cluster)"
  echo "3. Install vLLM (will pull additional dependencies)"
  echo ""
  
  # Extract and install PyTorch packages first (order matters!)
  echo "Step 1: Installing PyTorch packages..."
  grep -E "^(torch|torchaudio|torchvision)==" "$SEED_FILE" | while read -r pkg; do
    echo "  Installing: $pkg"
    pip install --index-url "$pytorch_index" "$pkg"
  done
  
  # Install Ray with exact version
  echo "Step 2: Installing Ray..."
  local ray_version=""  # Ray version from seed
  ray_version=$(grep "^ray==" "$SEED_FILE" | cut -d'=' -f3)
  if [[ -n "$ray_version" ]]; then
    pip install "ray==$ray_version"
  else
    echo "WARNING: Ray version not in seed file, installing latest"
    pip install ray
  fi
  
  # Install vLLM (will install triton and other deps)
  echo "Step 3: Installing vLLM..."
  local vllm_version=""  # vLLM version from seed
  vllm_version=$(grep "^vllm==" "$SEED_FILE" | cut -d'=' -f3)
  if [[ -n "$vllm_version" ]]; then
    pip install "vllm==$vllm_version"
  else
    echo "WARNING: vLLM version not in seed file, installing latest"
    pip install vllm
  fi
}

# InstallLatest - Fallback installation without seed file
#
# Arguments: None
# Outputs: pip installation progress to stdout
# Returns: 0 on success, non-zero on pip failure
# Globals: None
InstallLatest() {
  echo "Installing vLLM (latest versions - no seed file)"
  echo "WARNING: This may result in version mismatches across cluster nodes"
  echo ""
  
  # Install PyTorch with CUDA 12.9
  pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu129
  
  # Install Ray
  pip install ray
  
  # Install vLLM
  pip install vllm
}

# ValidateInstalledVersion - Check installed version and create manifest
#
# Arguments: None
# Outputs: Version info and manifest to stdout
# Returns: 0 if version valid, 1 if mismatch
# Globals: Reads VERSION_REQ, VENV_PATH
ValidateInstalledVersion() {
  local installed_ver=""  # Currently installed vLLM version
  local manifest_dir=""   # Directory for manifest output
  local manifest_file=""  # Manifest log file
  
  echo ""
  echo "=== Validating Installation ==="
  
  # Get installed versions
  installed_ver=$(python -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "0.0.0")
  
  echo "Installed vLLM version: $installed_ver"
  if [[ "$VERSION_REQ" != "latest" ]]; then
    echo "Required vLLM version: $VERSION_REQ"
  fi
  
  # Create manifest (similar to your vllm_manifest.sh)
  manifest_dir="/opt/ai-tools/logs/builds"
  manifest_file="${manifest_dir}/vllm_manifest_$(date +%Y%m%d_%H%M%S).log"
  mkdir -p "$manifest_dir"
  
  echo ""
  echo "=== Creating Environment Manifest ===" | tee "$manifest_file"
  
  python -c "
import sys
import torch
import vllm

print('Python:', sys.version, file=sys.stderr)
print('PyTorch:', torch.__version__, file=sys.stderr)
print('CUDA available:', torch.cuda.is_available(), file=sys.stderr)
if torch.cuda.is_available():
    print('CUDA version:', torch.version.cuda, file=sys.stderr)
    print('CUDA arch list:', torch.cuda.get_arch_list(), file=sys.stderr)
print('vLLM:', vllm.__version__, file=sys.stderr)

try:
    import ray
    print('Ray:', ray.__version__, file=sys.stderr)
except ImportError:
    print('Ray: NOT INSTALLED', file=sys.stderr)

try:
    import triton
    print('Triton:', triton.__version__, file=sys.stderr)
except ImportError:
    print('Triton: NOT INSTALLED', file=sys.stderr)
" 2>&1 | tee -a "$manifest_file"
  
  echo "" | tee -a "$manifest_file"
  echo "=== Full Package List ===" | tee -a "$manifest_file"
  pip freeze | grep -E "(vllm|torch|triton|ray|xformers|flash)" | sort | tee -a "$manifest_file"
  
  echo ""
  echo "Manifest saved to: $manifest_file"
  
  # Version validation
  if [[ "$VERSION_REQ" == "latest" ]]; then
    echo "No version requirement specified, accepting: $installed_ver"
    return 0
  fi
  
  if ! ValidateVersion "$installed_ver" "$VERSION_REQ"; then
    echo "WARNING: Version mismatch (installed $installed_ver, required $VERSION_REQ)"
    echo "This may cause issues in multi-node vLLM clusters"
    # Don't fail - just warn
  fi
  
  return 0
}

# BuildVLLM - Main build orchestration function
#
# Arguments: None
# Outputs: Build log to stdout
# Returns: 0 on success, 1 on failure
# Globals: Uses VENV_PATH, SEED_FILE, VERSION_REQ
BuildVLLM() {
  local log_file=""           # Log file path for this build
  
  log_file="/opt/ai-tools/logs/builds/vllm_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure log directory exists
  mkdir -p "$(dirname "$log_file")"
  
  {
    echo "=== Starting vLLM installation ==="
    
    EnsureVenv
    ValidateDependencies || return 1
    
    # Try to use seed file, fall back to latest if not found
    if LoadSeedFile; then
      InstallFromSeed
    else
      InstallLatest
    fi
    
    ValidateInstalledVersion || return 1
    
    echo ""
    echo "=== vLLM installation successful ==="
    echo "Virtual environment: $VENV_PATH"
    echo "Python: $(which python)"
    echo ""
    echo "To verify cluster compatibility, compare manifest with:"
    echo "  Node 1: ssh admin@192.168.2.42 'source /opt/ai-tools/vllm-env/bin/activate && python -c \"import vllm; print(vllm.__version__)\"'"
    echo "  Node 2: ssh admin@192.168.2.43 'source /opt/ai-tools/vllm-env/bin/activate && python -c \"import vllm; print(vllm.__version__)\"'"
    echo "  Node 3: ssh admin@192.168.2.44 'source /opt/ai-tools/vllm-env/bin/activate && python -c \"import vllm; print(vllm.__version__)\"'"
  } | tee "$log_file"
}

# CoreExec - Entry point for build script
#
# Arguments: None
# Outputs: Delegates to BuildVLLM
# Returns: Exit code from BuildVLLM
# Globals: None
CoreExec() {
  BuildVLLM
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec
