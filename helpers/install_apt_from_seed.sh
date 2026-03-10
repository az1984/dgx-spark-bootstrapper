#!/usr/bin/env bash
# install_apt_from_seed.sh
# Install APT packages from modular seed files with version locking
#
# This ensures all nodes have identical system packages, critical for:
# - CUDA toolkit versions (nvcc, ptxas, libraries)
# - Python system packages
# - Build tools (gcc, cmake, etc.)
#
# Supports modular seed files:
# - cuda_apt_packages.txt (CUDA toolkit, drivers, NCCL)
# - python_apt_packages.txt (Python system packages)
# - build_tools_apt_packages.txt (gcc, cmake, git, etc.)
# - system_all_apt_packages.txt (optional full system snapshot)
#
# Called by bootstrap_spark_node.sh before building AI components

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

SEED_DIR=""              # Directory containing seed files
PACKAGES=()              # Array of all packages to install
DRY_RUN="${DRY_RUN:-0}"  # If 1, only show what would be installed
INSTALL_ALL="${INSTALL_ALL:-0}"  # If 1, use system_all_apt_packages.txt

# ============================================================================
# Functions
# ============================================================================

# Log - Write log message to stdout
#
# Arguments: $@ - Message to log
# Outputs: Timestamped message to stdout
# Returns: 0 (always succeeds)
# Globals: None
Log() {
  echo "[install_apt_from_seed] $*"
}

# FindSeedDir - Locate seed files directory
#
# Arguments: None
# Outputs: Seed directory path to stdout if found
# Returns: 0 if found, 1 if not found
# Globals: Sets SEED_DIR
FindSeedDir() {
  local seed_locations=()  # Possible seed directory locations
  local loc=""             # Current location being checked
  local script_dir=""      # Directory containing this script
  
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  
  # Try multiple locations
  seed_locations=(
    "${script_dir}/seeds"
    "${script_dir}/../seeds"
    "/opt/ai-tools/seeds"
    "/opt/ai-tools/seed"
  )
  
  for loc in "${seed_locations[@]}"; do
    if [[ -d "$loc" ]]; then
      SEED_DIR="$loc"
      Log "Found seed directory: $SEED_DIR"
      return 0
    fi
  done
  
  Log "ERROR: No seed directory found"
  Log "Searched locations:"
  for loc in "${seed_locations[@]}"; do
    Log "  - $loc"
  done
  
  return 1
}

# ParseSeedFile - Extract package names from a seed file
#
# Arguments: $1 - Seed file path
# Outputs: Package names added to PACKAGES array
# Returns: 0 (always succeeds, may add zero packages)
# Globals: Appends to PACKAGES array
ParseSeedFile() {
  local seed_file="$1"  # Seed file to parse
  local line=""         # Current line being processed
  local pkg_name=""     # Package name (before =)
  local count=0         # Packages added from this file
  
  if [[ ! -f "$seed_file" ]]; then
    Log "WARNING: Seed file not found: $seed_file"
    return 0
  fi
  
  Log "Parsing: $(basename "$seed_file")"
  
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    
    # Extract package name (before =)
    pkg_name="${line%%=*}"
    
    # Remove any whitespace
    pkg_name="${pkg_name// /}"
    
    # Skip if empty after cleanup
    [[ -z "$pkg_name" ]] && continue
    
    PACKAGES+=("$pkg_name")
    ((count++))
  done < "$seed_file"
  
  Log "  Added $count packages"
  
  return 0
}

# LoadAllSeedFiles - Load packages from all modular seed files
#
# Arguments: None
# Outputs: Progress to stdout
# Returns: 0 if any packages loaded, 1 if none
# Globals: Reads SEED_DIR, INSTALL_ALL; sets PACKAGES array
LoadAllSeedFiles() {
  local seed_files=()  # List of seed files to process
  
  PACKAGES=()
  
  if [[ "$INSTALL_ALL" -eq 1 ]]; then
    Log "Using full system snapshot (system_all_apt_packages.txt)"
    seed_files=("${SEED_DIR}/system_all_apt_packages.txt")
  else
    Log "Using modular seed files"
    seed_files=(
      "${SEED_DIR}/cuda_apt_packages.txt"
      "${SEED_DIR}/python_apt_packages.txt"
      "${SEED_DIR}/build_tools_apt_packages.txt"
    )
  fi
  
  for seed_file in "${seed_files[@]}"; do
    ParseSeedFile "$seed_file"
  done
  
  # Remove duplicates (preserve order)
  local unique_packages=()
  local seen_packages=()
  local pkg=""
  
  for pkg in "${PACKAGES[@]}"; do
    if [[ ! " ${seen_packages[*]} " =~ " ${pkg} " ]]; then
      unique_packages+=("$pkg")
      seen_packages+=("$pkg")
    fi
  done
  
  PACKAGES=("${unique_packages[@]}")
  
  Log "Total unique packages to install: ${#PACKAGES[@]}"
  
  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    Log "ERROR: No packages found in any seed file"
    return 1
  fi
  
  return 0
}

# InstallPackages - Install packages via apt-get
#
# Arguments: None
# Outputs: apt-get progress to stdout
# Returns: 0 on success, non-zero on apt failure
# Globals: Reads PACKAGES array, DRY_RUN
InstallPackages() {
  local batch_size=50   # Install in batches to avoid command line length limits
  local i=0             # Current package index
  local batch=()        # Current batch of packages
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    Log "DRY RUN: Would install ${#PACKAGES[@]} packages:"
    printf '%s\n' "${PACKAGES[@]}" | head -20
    [[ ${#PACKAGES[@]} -gt 20 ]] && echo "... and $((${#PACKAGES[@]} - 20)) more"
    return 0
  fi
  
  Log "Updating package lists..."
  apt-get update
  
  Log "Installing ${#PACKAGES[@]} packages in batches of $batch_size..."
  
  for ((i=0; i<${#PACKAGES[@]}; i++)); do
    batch+=("${PACKAGES[$i]}")
    
    # Install batch when full or at end
    if [[ ${#batch[@]} -eq $batch_size ]] || [[ $((i+1)) -eq ${#PACKAGES[@]} ]]; then
      Log "Installing batch $((i / batch_size + 1)) (${#batch[@]} packages)..."
      
      # Use --no-install-recommends to avoid bloat
      # Use -y to auto-confirm
      # Allow failures for individual packages (some may not exist on this arch)
      apt-get install -y --no-install-recommends "${batch[@]}" 2>&1 | grep -v "^Selecting" || {
        Log "WARNING: Some packages in batch failed to install"
      }
      
      batch=()
    fi
  done
  
  Log "Package installation complete"
}

# VerifyCriticalPackages - Check that critical packages installed
#
# Arguments: None
# Outputs: Verification results to stdout
# Returns: 0 if critical packages present, 1 if missing
# Globals: None
VerifyCriticalPackages() {
  local critical_commands=(cmake gcc g++ git python3)  # Commands that should be in PATH
  local cmd=""          # Current command being checked
  local missing=()      # Missing critical commands
  
  Log "Verifying critical packages..."
  
  # Check commands in PATH
  for cmd in "${critical_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  # Check nvcc (special case - may not be in PATH yet)
  local nvcc_found=0
  if command -v nvcc >/dev/null 2>&1; then
    nvcc_found=1
  elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc_found=1
    Log "Found nvcc at /usr/local/cuda/bin/nvcc (not in PATH)"
  elif [[ -x /usr/local/cuda-13.0/bin/nvcc ]]; then
    nvcc_found=1
    Log "Found nvcc at /usr/local/cuda-13.0/bin/nvcc (not in PATH)"
  fi
  
  if [[ $nvcc_found -eq 0 ]]; then
    missing+=("nvcc")
  fi
  
  # Check python3-venv (special case - check python module)
  if ! python3 -c "import venv" 2>/dev/null; then
    missing+=("python3-venv")
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    Log "ERROR: Critical packages missing: ${missing[*]}"
    Log "AI component builds will fail without these"
    return 1
  fi
  
  Log "✓ All critical packages verified"
  
  # Show versions of key tools
  Log "Key package versions:"
  
  # nvcc version
  if command -v nvcc >/dev/null 2>&1; then
    Log "  CUDA compiler: $(nvcc --version 2>&1 | grep -oP 'release \K[0-9.]+' || echo 'unknown')"
  elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
    Log "  CUDA compiler: $(/usr/local/cuda/bin/nvcc --version 2>&1 | grep -oP 'release \K[0-9.]+' || echo 'unknown') (at /usr/local/cuda/bin)"
  elif [[ -x /usr/local/cuda-13.0/bin/nvcc ]]; then
    Log "  CUDA compiler: $(/usr/local/cuda-13.0/bin/nvcc --version 2>&1 | grep -oP 'release \K[0-9.]+' || echo 'unknown') (at /usr/local/cuda-13.0/bin)"
  fi
  
  Log "  CMake: $(cmake --version 2>&1 | head -1 | grep -oP '[0-9.]+' || echo 'unknown')"
  Log "  GCC: $(gcc --version 2>&1 | head -1 | grep -oP '[0-9.]+' | head -1 || echo 'unknown')"
  Log "  Python: $(python3 --version 2>&1 | grep -oP '[0-9.]+' || echo 'unknown')"
  
  return 0
}

# CoreExec - Main execution function
#
# Arguments: None
# Outputs: Delegates to other functions
# Returns: Exit code (0 for success, non-zero for failure)
# Globals: Uses all globals
CoreExec() {
  Log "Starting APT seed installation"
  
  if ! FindSeedDir; then
    Log "No seed directory found, cannot proceed"
    exit 1
  fi
  
  if ! LoadAllSeedFiles; then
    Log "Failed to load seed files"
    exit 1
  fi
  
  InstallPackages || {
    Log "Package installation encountered errors"
    Log "Continuing to verification..."
  }
  
  if ! VerifyCriticalPackages; then
    Log "WARNING: Critical packages missing after install"
    Log "Component builds may fail"
    exit 1
  fi
  
  Log "✓ APT seed installation complete"
  exit 0
}

# ============================================================================
# Entry Point
# ============================================================================

# Require root
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)"
  exit 1
fi

CoreExec
