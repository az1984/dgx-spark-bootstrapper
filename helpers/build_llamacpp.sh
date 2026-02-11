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

REPOURLDEFAULT="https://github.com/ggml-org/llama.cpp"

SRCDEFAULT="/opt/ai-tools/src/llama.cpp"
BUILDROOTDEFAULT="/opt/ai-tools/build/llama.cpp"
PREFIXDEFAULT="/opt/ai-tools/llama.cpp"

PRESETDEFAULT=""   # auto: linux->cuda, darwin->metal
DOUPDATE=0
DOCLEAN=0
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

Usage() {
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
}

Log() { printf '[build_llamacpp] %s\n' "$*"; }
Die() { printf '[build_llamacpp] ERROR: %s\n' "$*" >&2; exit 1; }

FindCudaCompiler() {
  # Prefer explicit env overrides
  if [[ -n "${CUDACXX:-}" && -x "${CUDACXX}" ]]; then
    echo "${CUDACXX}"
    return 0
  fi

  # Common CUDA locations on Linux (including ARM SBSA)
  local candidates=(
    "/usr/local/cuda/bin/nvcc"
    "/usr/local/cuda-13.0/bin/nvcc"
    "/usr/local/cuda-12.*/bin/nvcc"
    "/usr/bin/nvcc"
  )

  local c
  for c in "${candidates[@]}"; do
    # allow globs
    for expanded in $c; do
      if [[ -x "${expanded}" ]]; then
        echo "${expanded}"
        return 0
      fi
    done
  done

  if command -v nvcc >/dev/null 2>&1; then
    command -v nvcc
    return 0
  fi

  return 1
}

EnsureCudaCompiler() {
  local nvcc
  nvcc="$(FindCudaCompiler || true)"

  if [[ -z "${nvcc}" ]]; then
    Die "CUDA preset selected but nvcc (CUDA compiler) was not found.\n\nCMake may still detect CUDA headers/libraries (e.g., /usr/local/cuda/targets/*/include), but llama.cpp CUDA builds require nvcc.\n\nFix options:\n  1) Install the full CUDA toolkit that provides nvcc (not just runtime/headers), then re-run.\n  2) Or build CPU-only: --preset cpu\n\nTo confirm after install: \`nvcc --version\` and ensure /usr/local/cuda/bin is on PATH."
  fi

  export CUDACXX="${nvcc}"
  Log "Using CUDA compiler: ${CUDACXX}"
}

OsDefaultPreset() {
  local unameS
  unameS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "${unameS}" == "darwin" ]]; then
    echo "metal"
  else
    echo "cuda"
  fi
}

EnsureParentDir() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
}

CloneIfNeeded() {
  local repoUrl="$1"
  local srcDir="$2"

  if [[ -d "${srcDir}/.git" ]]; then
    Log "Source exists: ${srcDir}"
    return 0
  fi

  EnsureParentDir "${srcDir}"
  Log "Cloning llama.cpp into ${srcDir}"
  git clone "${repoUrl}" "${srcDir}"
}

UpdateRepoIfRequested() {
  local srcDir="$1"
  [[ "${DOUPDATE}" -eq 1 ]] || return 0

  [[ -d "${srcDir}/.git" ]] || Die "Cannot update: ${srcDir} is not a git repo"

  Log "Updating repo (git fetch + pull): ${srcDir}"
  (cd "${srcDir}" && git fetch --all --prune && git pull --ff-only)
}

BuildDirForPreset() {
  local buildRoot="$1"
  local preset="$2"

  case "${preset}" in
    cuda)  echo "${buildRoot}/build-cuda" ;;
    metal) echo "${buildRoot}/build-metal" ;;
    cpu)   echo "${buildRoot}/build-cpu" ;;
    *)     Die "Unknown preset: ${preset}" ;;
  esac
}

ConfigureCmake() {
  local srcDir="$1"
  local buildDir="$2"
  local preset="$3"
  local prefix="$4"

  mkdir -p "${buildDir}"

  # On Linux, make installed binaries look for shared libs relative to the install prefix.
  # This avoids relying on ldconfig/ld.so.conf.d for /opt-style prefixes.
  local rpathArgs=()
  if IsLinux; then
    rpathArgs=(
      -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib'
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    )
  fi

  case "${preset}" in
    cuda)
      Log "Configuring CMake (CUDA): ${buildDir}"
      cmake -S "${srcDir}" -B "${buildDir}" \
        -DGGML_CUDA=ON \
		-DCMAKE_CUDA_COMPILER="${CUDACXX}" \
        "${rpathArgs[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    metal)
      Log "Configuring CMake (Metal): ${buildDir}"
      cmake -S "${srcDir}" -B "${buildDir}" \
        -DGGML_METAL=ON \
        "${rpathArgs[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    cpu)
      Log "Configuring CMake (CPU): ${buildDir}"
      cmake -S "${srcDir}" -B "${buildDir}" \
        -DGGML_CUDA=OFF -DGGML_METAL=OFF \
        "${rpathArgs[@]}" \
        -DCMAKE_INSTALL_PREFIX="${prefix}"
      ;;
    *)
      Die "Unknown preset: ${preset}"
      ;;
  esac
}

Build() {
  local buildDir="$1"
  Log "Building: ${buildDir} (jobs=${JOBS})"
  cmake --build "${buildDir}" -j"${JOBS}"
}

Install() {
  local buildDir="$1"
  local prefix="$2"

  Log "Installing into: ${prefix}"
  mkdir -p "${prefix}"
  cmake --install "${buildDir}"
}

# Returns true if not running on macOS (i.e., running on Linux)
IsLinux() {
  local unameS
  unameS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  [[ "${unameS}" != "darwin" ]]
}

# Performs post-installation checks for shared library issues (Linux)
PostInstallSanity() {
  local prefix="$1"
  local cli="${prefix}/bin/llama-cli"

  if [[ ! -x "${cli}" ]]; then
    Log "Post-install sanity: llama-cli not found/executable at ${cli}"
    return 0
  fi

  if IsLinux; then
    Log "Post-install sanity: checking dynamic linker deps for llama-cli"
    if command -v ldd >/dev/null 2>&1; then
      local missing
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

PrintVersionIfAvailable() {
  local prefix="$1"
  local cli="${prefix}/bin/llama-cli"

  if [[ -x "${cli}" ]]; then
    Log "llama-cli version:"
    "${cli}" --version || true
  else
    Log "llama-cli not found at ${cli}"
  fi
}

# ------------------------------------------------------------------------------
# Arg parsing
# ------------------------------------------------------------------------------

SRCDIR="${SRCDEFAULT}"
BUILDROOT="${BUILDROOTDEFAULT}"
PREFIX="${PREFIXDEFAULT}"
REPOURL="${REPOURLDEFAULT}"
PRESET="${PRESETDEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRCDIR="$2"; shift 2;;
    --build-root) BUILDROOT="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --repo) REPOURL="$2"; shift 2;;
    --preset) PRESET="$2"; shift 2;;
    --jobs) JOBS="$2"; shift 2;;
    --update) DOUPDATE=1; shift 1;;
    --clean) DOCLEAN=1; shift 1;;
    --help|-h) Usage; exit 0;;
    *) Die "Unknown argument: $1 (use --help)";;
  esac
done

if [[ -z "${PRESET}" ]]; then
  PRESET="$(OsDefaultPreset)"
fi

BUILDDIR="$(BuildDirForPreset "${BUILDROOT}" "${PRESET}")"

Log "Using:"
Log "  repo:       ${REPOURL}"
Log "  src:        ${SRCDIR}"
Log "  build-root: ${BUILDROOT}"
Log "  prefix:     ${PREFIX}"
Log "  preset:     ${PRESET}"
Log "  build-dir:  ${BUILDDIR}"
Log "  update:     ${DOUPDATE}"
Log "  clean:      ${DOCLEAN}"
Log "  jobs:       ${JOBS}"

command -v git >/dev/null 2>&1 || Die "git not found"
command -v cmake >/dev/null 2>&1 || Die "cmake not found"

# CUDA builds require nvcc; fail early with a clear message if missing.
if [[ "${PRESET}" == "cuda" ]]; then
  EnsureCudaCompiler
fi

CloneIfNeeded "${REPOURL}" "${SRCDIR}"
UpdateRepoIfRequested "${SRCDIR}"

if [[ "${DOCLEAN}" -eq 1 ]]; then
  Log "Cleaning build dir: ${BUILDDIR}"
  rm -rf "${BUILDDIR}"
fi

ConfigureCmake "${SRCDIR}" "${BUILDDIR}" "${PRESET}" "${PREFIX}"
Build "${BUILDDIR}"
Install "${BUILDDIR}" "${PREFIX}"
PostInstallSanity "${PREFIX}"
PrintVersionIfAvailable "${PREFIX}"

Log "Done."
