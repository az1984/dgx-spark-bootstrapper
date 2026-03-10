#!/usr/bin/env bash
# build_llamacpp.sh
#
# Canonical llama.cpp checkout + build + install wrapper for macOS (Metal) + Linux (CUDA/CPU).
#
# Layout contract:
# - Source checkout:  /opt/ai-tools/src/llama.cpp
# - Build outputs:    /opt/ai-tools/build/llama.cpp/build-{cuda|metal|cpu}
# - Install prefix:   /opt/ai-tools/llama.cpp (binaries live in /opt/ai-tools/llama.cpp/bin)
#
# Uses upstream canonical DGX Spark build pattern:
#   cmake -B build-cuda -DGGML_CUDA=ON
#   cmake --build build-cuda -j
# …and adds:
#   cmake --install build-cuda
#
# Idempotent:
# - Clones if missing
# - Optional --update does git fetch/pull
# - Optional --clean deletes only the selected build dir
# - Always (re)installs into --prefix after build

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

REPO_URL_DEFAULT="https://github.com/ggml-org/llama.cpp"  # Default git repo URL

SRC_DEFAULT="/opt/ai-tools/src/llama.cpp"                 # Default source directory
BUILD_ROOT_DEFAULT="/opt/ai-tools/build/llama.cpp"        # Default build root
PREFIX_DEFAULT="/opt/ai-tools/llama.cpp"                  # Default install prefix

PRESET_DEFAULT=""                                          # Auto-detect: linux->cuda, darwin->metal
DO_UPDATE=0                                                # Flag: git fetch/pull before build
DO_CLEAN=0                                                 # Flag: delete build dir before build
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" # Parallel build jobs

# Set by argument parsing
SRC_DIR="${SRC_DEFAULT}"                                   # Source checkout directory
BUILD_ROOT="${BUILD_ROOT_DEFAULT}"                         # Build root directory
PREFIX="${PREFIX_DEFAULT}"                                 # Install prefix
REPO_URL="${REPO_URL_DEFAULT}"                             # Git repo URL
PRESET="${PRESET_DEFAULT}"                                 # Build preset (cuda|metal|cpu)
BUILD_DIR=""                                               # Build directory (derived from preset)

# ============================================================================
# Utility Functions
# ============================================================================

# ShowUsage - Display help text and exit
#
# Arguments: None
# Outputs: Usage text to stdout
# Returns: Exits with code 0
# Globals: None
ShowUsage() {
  cat <<'USAGE'
Usage:
  build_llamacpp.sh [options]

Options:
  --src <path>                Source checkout directory
                              Default: /opt/ai-tools/src/llama.cpp

  --build-root <path>         Build root directory (contains build-* subdirs)
                              Default: /opt/ai-tools/build/llama.cpp

  --prefix <path>             Install prefix directory (installs into <prefix>/bin, etc.)
                              Default: /opt/ai-tools/llama.cpp

  --repo <url>                Repo URL (for first clone)
                              Default: https://github.com/ggml-org/llama.cpp

  --preset <cuda|metal|cpu>   Build preset. If omitted:
                                - Linux: cuda
                                - macOS: metal

  --jobs <n>                  Parallel build jobs
                              Default: detected CPU count

  --update                    git fetch/pull before building
  --clean                     remove the selected build directory before building
  --help                      show this help

Examples (DGX Spark / Linux CUDA):
  sudo ./build_llamacpp.sh \
    --src /opt/ai-tools/src/llama.cpp \
    --build-root /opt/ai-tools/build/llama.cpp \
    --prefix /opt/ai-tools/llama.cpp \
    --preset cuda --update

Example (macOS / Metal):
  ./build_llamacpp.sh --preset metal --update
USAGE
  exit 0
}

# Log - Write log message with prefix
#
# Arguments: All message components ($@)
# Outputs: Formatted message to stdout
# Returns: 0 (always succeeds)
# Globals: None
Log() {
  printf '[build_llamacpp] %s\n' "$*"
}

# Die - Write error message and exit
#
# Arguments: All error message components ($@)
# Outputs: Formatted error to stderr
# Returns: Exits with code 1
# Globals: None
Die() {
  printf '[build_llamacpp] ERROR: %s\n' "$*" >&2
  exit 1
}

# FindCUDACompiler - Locate CUDA compiler (nvcc)
#
# Arguments: None
# Outputs: Path to nvcc to stdout
# Returns: 0 if found, 1 if not found
# Globals: Reads CUDACXX (optional override)
FindCUDACompiler() {
  local candidates=()          # List of potential nvcc paths
  local c=""                   # Current candidate being checked
  local expanded=""            # Expanded glob pattern
  
  # Prefer explicit env overrides
  if [[ -n "${CUDACXX:-}" && -x "${CUDACXX}" ]]; then
    echo "${CUDACXX}"
    return 0
  fi

  # Common CUDA locations on Linux (including ARM SBSA)
  candidates=(
    "/usr/local/cuda/bin/nvcc"
    "/usr/local/cuda-13.0/bin/nvcc"
    "/usr/local/cuda-12.*/bin/nvcc"
    "/usr/bin/nvcc"
  )

  for c in "${candidates[@]}"; do
    # Allow globs
    for expanded in $c; do
      if [[ -x "${expanded}" ]]; then
        echo "${expanded}"
        return 0
      fi
    done
  done

  # Check PATH
  if command -v nvcc >/dev/null 2>&1; then
    command -v nvcc
    return 0
  fi

  return 1
}

# EnsureCUDACompiler - Verify CUDA compiler is available, exit if not
#
# Arguments: None
# Outputs: Status message via Log, error via Die
# Returns: Exits on failure, 0 on success
# Globals: Sets CUDACXX
EnsureCUDACompiler() {
  local nvcc=""                # Path to CUDA compiler
  
  nvcc="$(FindCUDACompiler || true)"

  if [[ -z "${nvcc}" ]]; then
    Die "CUDA preset selected but nvcc (CUDA compiler) was not found.\n\nCMake may still detect CUDA headers/libraries (e.g., /usr/local/cuda/targets/*/include), but llama.cpp CUDA builds require nvcc.\n\nFix options:\n  1) Install the full CUDA toolkit that provides nvcc (not just runtime/headers), then re-run.\n  2) Or build CPU-only: --preset cpu\n\nTo confirm after install: \`nvcc --version\` and ensure /usr/local/cuda/bin is on PATH."
  fi

  export CUDACXX="${nvcc}"
  Log "Using CUDA compiler: ${CUDACXX}"
}

# OSDefaultPreset - Determine default preset based on OS
#
# Arguments: None
# Outputs: Preset name (cuda|metal) to stdout
# Returns: 0 (always succeeds)
# Globals: None
OSDefaultPreset() {
  local uname_s=""             # Lowercase OS name
  
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  
  if [[ "${uname_s}" == "darwin" ]]; then
    echo "metal"
  else
    echo "cuda"
  fi
}

# EnsureParentDir - Create parent directory if missing
#
# Arguments:
#   $1 - path (string)
# Outputs: None
# Returns: 0 (always succeeds with set -e)
# Globals: None
EnsureParentDir() {
  local path="$1"              # Path whose parent should exist
  mkdir -p "$(dirname "${path}")"
}

# CloneIfNeeded - Clone repo if not already present
#
# Arguments:
#   $1 - repo_url (string)
#   $2 - src_dir (string)
# Outputs: Status messages via Log
# Returns: 0 (always succeeds with set -e)
# Globals: None
CloneIfNeeded() {
  local repo_url="$1"          # Git repository URL
  local src_dir="$2"           # Target source directory

  if [[ -d "${src_dir}/.git" ]]; then
    Log "Source exists: ${src_dir}"
    return 0
  fi

  EnsureParentDir "${src_dir}"
  Log "Cloning llama.cpp into ${src_dir}"
  git clone "${repo_url}" "${src_dir}"
}

# UpdateRepoIfRequested - Update git repo if --update flag set
#
# Arguments:
#   $1 - src_dir (string)
# Outputs: Status messages via Log
# Returns: 0 if skipped or succeeded (set -e handles git failures)
# Globals: Reads DO_UPDATE
UpdateRepoIfRequested() {
  local src_dir="$1"           # Source directory to update
  
  [[ "${DO_UPDATE}" -eq 1 ]] || return 0

  [[ -d "${src_dir}/.git" ]] || Die "Cannot update: ${src_dir} is not a git repo"

  Log "Updating repo (git fetch + pull): ${src_dir}"
  (cd "${src_dir}" && git fetch --all --prune && git pull --ff-only)
}

# BuildDirForPreset - Determine build directory from preset
#
# Arguments:
#   $1 - build_root (string)
#   $2 - preset (string: cuda|metal|cpu)
# Outputs: Build directory path to stdout
# Returns: Exits on unknown preset, 0 otherwise
# Globals: None
BuildDirForPreset() {
  local build_root="$1"        # Build root directory
  local preset="$2"            # Build preset

  case "${preset}" in
    cuda)  echo "${build_root}/build-cuda" ;;
    metal) echo "${build_root}/build-metal" ;;
    cpu)   echo "${build_root}/build-cpu" ;;
    *)     Die "Unknown preset: ${preset}" ;;
  esac
}

# ConfigureCMake - Run CMake configuration for preset
#
# Arguments:
#   $1 - src_dir (string)
#   $2 - build_dir (string)
#   $3 - preset (string: cuda|metal|cpu)
#   $4 - prefix (string)
# Outputs: CMake configuration output to stdout
# Returns: 0 on success (set -e handles cmake failures)
# Globals: Reads CUDACXX (for CUDA builds)
ConfigureCMake() {
  local src_dir="$1"           # Source directory
  local build_dir="$2"         # Build directory
  local preset="$3"            # Build preset
  local prefix="$4"            # Install prefix
  local rpath_args=()          # RPATH arguments for Linux

  mkdir -p "${build_dir}"

  # On Linux, make installed binaries look for shared libs relative to the install prefix.
  # This avoids relying on ldconfig/ld.so.conf.d for /opt-style prefixes.
  if IsLinux; then
    rpath_args=(
      -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib'
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    )
  fi

  case "${preset}" in
    cuda)
      Log "Configuring CMake (CUDA): ${build_dir}"
      cmake -S "${src_dir}" -B "${build_dir}" \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_COMPILER="${CUDACXX}" \
        "${rpath_args[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    metal)
      Log "Configuring CMake (Metal): ${build_dir}"
      cmake -S "${src_dir}" -B "${build_dir}" \
        -DGGML_METAL=ON \
        "${rpath_args[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    cpu)
      Log "Configuring CMake (CPU): ${build_dir}"
      cmake -S "${src_dir}" -B "${build_dir}" \
        -DGGML_CUDA=OFF -DGGML_METAL=OFF \
        "${rpath_args[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    *)
      Die "Unknown preset: ${preset}"
      ;;
  esac
}

# Build - Run CMake build
#
# Arguments:
#   $1 - build_dir (string)
# Outputs: Build output to stdout
# Returns: 0 on success (set -e handles failures)
# Globals: Reads JOBS
Build() {
  local build_dir="$1"         # Build directory
  
  Log "Building: ${build_dir} (jobs=${JOBS})"
  cmake --build "${build_dir}" -j"${JOBS}"
}

# Install - Run CMake install
#
# Arguments:
#   $1 - build_dir (string)
#   $2 - prefix (string)
# Outputs: Install output to stdout
# Returns: 0 on success (set -e handles failures)
# Globals: None
Install() {
  local build_dir="$1"         # Build directory
  local prefix="$2"            # Install prefix

  Log "Installing into: ${prefix}"
  mkdir -p "${prefix}"
  cmake --install "${build_dir}"
}

# IsLinux - Check if running on Linux (not macOS)
#
# Arguments: None
# Outputs: None
# Returns: 0 if Linux, 1 if macOS
# Globals: None
IsLinux() {
  local uname_s=""             # Lowercase OS name
  
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  [[ "${uname_s}" != "darwin" ]]
}

# PostInstallSanity - Check for missing shared libraries (Linux only)
#
# Arguments:
#   $1 - prefix (string)
# Outputs: Sanity check results via Log
# Returns: 0 (always succeeds, warnings only)
# Globals: None
PostInstallSanity() {
  local prefix="$1"            # Install prefix
  local cli=""                 # Path to llama-cli binary
  local missing=""             # Missing libraries output

  cli="${prefix}/bin/llama-cli"

  if [[ ! -x "${cli}" ]]; then
    Log "Post-install sanity: llama-cli not found/executable at ${cli}"
    return 0
  fi

  if IsLinux; then
    Log "Post-install sanity: checking dynamic linker deps for llama-cli"
    
    if command -v ldd >/dev/null 2>&1; then
      missing="$(ldd "${cli}" 2>/dev/null | awk '/not found/ {print}')"
      
      if [[ -n "${missing}" ]]; then
        Log "Post-install sanity: missing shared libraries detected:"
        printf '%s\n' "${missing}"
        Log "Hint: add ${prefix}/lib to ld.so.conf.d and run ldconfig (requires root):"
        Log "  echo \"${prefix}/lib\" | sudo tee /etc/ld.so.conf.d/ai-tools-llama.conf >/dev/null"
        Log "  sudo ldconfig"
      else
        Log "Post-install sanity: no missing shared libraries detected"
      fi
    else
      Log "Post-install sanity: ldd not available; skipping"
    fi
  fi
}

# PrintVersionIfAvailable - Display installed version
#
# Arguments:
#   $1 - prefix (string)
# Outputs: Version info via Log
# Returns: 0 if version check passes, 1 on mismatch
# Globals: None
PrintVersionIfAvailable() {
  local prefix="$1"            # Install prefix
  local cli=""                 # Path to llama-cli binary
  local installed_ver=""       # Installed version string
  local required_ver=""        # Required version from versions.txt

  cli="${prefix}/bin/llama-cli"

  if [[ ! -x "${cli}" ]]; then
    Log "llama-cli not found at ${cli}"
    return 1
  fi

  installed_ver="$("${cli}" --version 2>&1 | head -1)"
  Log "llama-cli version: $installed_ver"
  
  # Version validation if versions.txt exists
  if [[ -f "/opt/ai-configuration/desired_state/versions.txt" ]]; then
    source "$(dirname "$0")/semver.sh" 2>/dev/null || true
    source "$(dirname "$0")/tui.sh" 2>/dev/null || true
    
    required_ver="$(grep "llama" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2 || echo "")"
    
    if [[ -n "$required_ver" ]] && command -v ValidateVersion >/dev/null 2>&1; then
      if ! ValidateVersion "$installed_ver" "$required_ver"; then
        Log "Version mismatch: installed $installed_ver, wanted $required_ver"
        
        if command -v PromptVersionMismatch >/dev/null 2>&1; then
          PromptVersionMismatch "llama" "$installed_ver" "$required_ver"
          case $? in
            0) return 0 ;;  # User chose to proceed
            1)  # User deferred
               mkdir -p "/opt/ai-configuration/remediation_cookies"
               touch "/opt/ai-configuration/remediation_cookies/llama.cookie"
               return 1
               ;;
            *)  # User cancelled
               exit 1
               ;;
          esac
        fi
      fi
    fi
  fi
  
  return 0
}

# ============================================================================
# Argument Parsing
# ============================================================================

# ParseArgsCLI - Parse command-line arguments
#
# Arguments: All command-line args ($@)
# Outputs: None
# Returns: Exits via ShowUsage on invalid args, 0 otherwise
# Globals: Sets SRC_DIR, BUILD_ROOT, PREFIX, REPO_URL, PRESET, JOBS, DO_UPDATE, DO_CLEAN
ParseArgsCLI() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --src)
        SRC_DIR="$2"
        shift 2
        ;;
      --build-root)
        BUILD_ROOT="$2"
        shift 2
        ;;
      --prefix)
        PREFIX="$2"
        shift 2
        ;;
      --repo)
        REPO_URL="$2"
        shift 2
        ;;
      --preset)
        PRESET="$2"
        shift 2
        ;;
      --jobs)
        JOBS="$2"
        shift 2
        ;;
      --update)
        DO_UPDATE=1
        shift 1
        ;;
      --clean)
        DO_CLEAN=1
        shift 1
        ;;
      --help|-h)
        ShowUsage
        ;;
      *)
        Die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done

  # Auto-detect preset if not specified
  if [[ -z "${PRESET}" ]]; then
    PRESET="$(OSDefaultPreset)"
  fi

  # Derive build directory from preset
  BUILD_DIR="$(BuildDirForPreset "${BUILD_ROOT}" "${PRESET}")"
}

# ============================================================================
# Main Execution
# ============================================================================

# CoreExec - Main execution function
#
# Arguments: All command-line args ($@)
# Outputs: Build progress and results via Log
# Returns: 0 on success, exits on failure
# Globals: Uses all global config variables
CoreExec() {
  ParseArgsCLI "$@"

  Log "Using:"
  Log "  repo:       ${REPO_URL}"
  Log "  src:        ${SRC_DIR}"
  Log "  build-root: ${BUILD_ROOT}"
  Log "  prefix:     ${PREFIX}"
  Log "  preset:     ${PRESET}"
  Log "  build-dir:  ${BUILD_DIR}"
  Log "  update:     ${DO_UPDATE}"
  Log "  clean:      ${DO_CLEAN}"
  Log "  jobs:       ${JOBS}"

  # Verify dependencies
  command -v git >/dev/null 2>&1 || Die "git not found"
  command -v cmake >/dev/null 2>&1 || Die "cmake not found"

  # CUDA builds require nvcc; fail early with a clear message if missing
  if [[ "${PRESET}" == "cuda" ]]; then
    EnsureCUDACompiler
  fi

  # Build workflow
  CloneIfNeeded "${REPO_URL}" "${SRC_DIR}"
  UpdateRepoIfRequested "${SRC_DIR}"

  if [[ "${DO_CLEAN}" -eq 1 ]]; then
    Log "Cleaning build dir: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
  fi

  ConfigureCMake "${SRC_DIR}" "${BUILD_DIR}" "${PRESET}" "${PREFIX}"
  Build "${BUILD_DIR}"
  Install "${BUILD_DIR}" "${PREFIX}"
  PostInstallSanity "${PREFIX}"
  PrintVersionIfAvailable "${PREFIX}"

  Log "Done."
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
