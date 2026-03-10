#!/usr/bin/env bash
# bootstrap_node.sh
# One-shot node bootstrap for DGX Spark toolchain.
#
# Idempotent: safe to re-run.
#
# Install scope:
# - Tool present + (optional) basic model downloaded + heartbeat.
# - Model downloads are delegated to a separate script: /opt/ai-tools/scripts/seed_models.sh
#
# Directory skeleton:
# - Ensures /opt/ai-* directories exist with expected ownership + permissions.
# - Check in one function; act in separate functions for safety.
# - Extra safety: refuses to chown/chmod a NON-EMPTY directory if owner/group mismatch.

set -euo pipefail

PRE_LOG_DIR="/var/log/ai-bootstrap"
OPT_LOG_DIR="/opt/ai-tools/logs/bootstrap"

# Phase flag: 0 = log to PRE_LOG_DIR, 1 = log to OPT_LOG_DIR
USE_OPT_LOGS="${USE_OPT_LOGS:-0}"

SEED_DIR="/opt/ai-tools/seed"
AI_TOOLS="/opt/ai-tools"
AI_STACKS="/opt/ai-stack"
AI_MODELS="/opt/ai-models"

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-admin}}"
ADMIN_GROUP="${ADMIN_GROUP:-admin}"

VLLM_VENV="${AI_TOOLS}/vllm-env"
VLLM_LOCK="${SEED_DIR}/pip.vllm-env.spark1.txt"

LLAMA_SRC="${AI_TOOLS}/src/llama.cpp"
LLAMA_BUILD="${AI_TOOLS}/build/llama.cpp"
LLAMA_PREFIX="${AI_TOOLS}/llama.cpp"
LLAMA_BUILD_SCRIPT="${AI_TOOLS}/scripts/build_llamacpp.sh"

COMFYUI_SRC="${AI_TOOLS}/src/ComfyUI"
COMFYUI_VENV="${AI_TOOLS}/comfyui-env"

KOKORO_VENV="${AI_TOOLS}/kokoro-env"

SEED_MODELS_SCRIPT="${AI_TOOLS}/scripts/seed_models.sh"

# Feature flags (override via env)
INSTALL_APT_DEFAULT="${INSTALL_APT_DEFAULT:-1}"
INSTALL_DOCKER_DEFAULT="${INSTALL_DOCKER_DEFAULT:-1}"
INSTALL_PODMAN_DEFAULT="${INSTALL_PODMAN_DEFAULT:-0}"

BUILDLLAMADEFAULT="${BUILDLLAMADEFAULT:-1}"
INSTALL_VLLM="${INSTALL_VLLM:-1}"

INSTALL_COMFYUI_DEFAULT="${INSTALL_COMFYUI_DEFAULT:-1}"
INSTALL_TTS_DEFAULT="${INSTALL_TTS_DEFAULT:-1}"
INSTALL_WHISPER_DEFAULT="${INSTALL_WHISPER_DEFAULT:-0}"
INSTALL_DIA_DEFAULT="${INSTALL_DIA_DEFAULT:-0}"

SEED_MODELS_DEFAULT="${SEED_MODELS_DEFAULT:-1}"
RUN_HEARTBEATS_DEFAULT="${RUN_HEARTBEATS_DEFAULT:-1}"

RequireRoot() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)."
    exit 1
  fi
}

Log() {
  local target_dir
  if [[ "${USE_OPT_LOGS}" -eq 1 ]]; then
    target_dir="${OPT_LOG_DIR}"
  else
    target_dir="${PRE_LOG_DIR}"
  fi

  mkdir -p "${target_dir}"
  echo "[bootstrap] $*" | tee -a "${target_dir}/bootstrap.log"
}

HaveCmd() { command -v "$1" >/dev/null 2>&1; }

DirHasContents() {
  local path="$1"
  [[ -d "${path}" ]] || return 1
  shopt -s nullglob dotglob
  local items=("${path}"/*)
  shopt -u nullglob dotglob
  [[ ${#items[@]} -gt 0 ]]
}

# Spec format: path|owner|group|mode
DIR_SPECS=(
  "/opt/ai-models|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-models/hf|${ADMIN_USER}|${ADMIN_GROUP}|775"
  "/opt/ai-stack|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-stack/compose|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-stack/env|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-tools|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-tools/build|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-tools/llama.cpp|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-tools/logs|root|root|755"
  "/opt/ai-tools/run|root|root|755"
  "/opt/ai-tools/scripts|${ADMIN_USER}|${ADMIN_GROUP}|775"
  "/opt/ai-tools/seed|${ADMIN_USER}|${ADMIN_GROUP}|775"
  "/opt/ai-tools/src|${ADMIN_USER}|${ADMIN_GROUP}|755"
  "/opt/ai-tools/vllm-env|${ADMIN_USER}|${ADMIN_GROUP}|755"
)

# Populated by CheckDirSkeleton
NEEDS_FIX=()

_DirStateOk() {
  local path="$1" owner="$2" group="$3" mode="$4"

  if [[ ! -d "${path}" ]]; then
    return 1
  fi

  local st_owner st_group st_mode
  st_owner="$(stat -c '%U' "${path}")"
  st_group="$(stat -c '%G' "${path}")"
  st_mode="$(stat -c '%a' "${path}")"

  [[ "${st_owner}" == "${owner}" && "${st_group}" == "${group}" && "${st_mode}" == "${mode}" ]]
}

CheckDirSkeleton() {
  NEEDS_FIX=()
  local spec path owner group mode

  for spec in "${DIR_SPECS[@]}"; do
    IFS='|' read -r path owner group mode <<< "${spec}"
    if _DirStateOk "${path}" "${owner}" "${group}" "${mode}"; then
      continue
    fi
    NEEDS_FIX+=("${spec}")
  done

  if [[ "${#NEEDS_FIX[@]}" -eq 0 ]]; then
    Log "Directory skeleton check: OK"
    return 0
  fi

  Log "Directory skeleton check: needs changes (${#NEEDS_FIX[@]} item(s))"
  for spec in "${NEEDS_FIX[@]}"; do
    IFS='|' read -r path owner group mode <<< "${spec}"
    if [[ ! -d "${path}" ]]; then
      Log "  - missing: ${path} (want ${owner}:${group} ${mode})"
      continue
    fi
    Log "  - mismatch: ${path} (want ${owner}:${group} ${mode})"
  done
  return 1
}

EnsureDirExists() {
  local path="$1"
  [[ -d "${path}" ]] || mkdir -p "${path}"
}

FixDirPerms() {
  local path="$1" owner="$2" group="$3" mode="$4"
  chown "${owner}:${group}" "${path}"
  chmod "${mode}" "${path}"
}

ApplyDirSkeletonFixes() {
  if [[ "${#NEEDS_FIX[@]}" -eq 0 ]]; then
    return 0
  fi

  Log "Applying directory skeleton fixes..."
  local spec path owner group mode
  local st_owner st_group

  for spec in "${NEEDS_FIX[@]}"; do
    IFS='|' read -r path owner group mode <<< "${spec}"

    if [[ -d "${path}" ]]; then
      st_owner="$(stat -c '%U' "${path}")"
      st_group="$(stat -c '%G' "${path}")"

      # Extra safety: refuse to change a non-empty dir if owner/group mismatch.
      if DirHasContents "${path}" && [[ "${st_owner}" != "${owner}" || "${st_group}" != "${group}" ]]; then
        Log "ERROR: refusing to change non-empty directory with mismatched ownership:"
        Log "  path: ${path}"
        Log "  current: ${st_owner}:${st_group}"
        Log "  desired: ${owner}:${group}"
        Log "Fix ownership manually (or empty/move contents) and re-run."
        exit 1
      fi
    fi

    EnsureDirExists "${path}"
    FixDirPerms "${path}" "${owner}" "${group}" "${mode}"
  done

  # Re-check to ensure desired state
  CheckDirSkeleton
}

InstallApt() {
  Log "Installing baseline apt packages..."
  apt-get update

  # Baseline system + tooling
  apt-get install -y \
    openssh-server rsync git curl jq aria2 \
    python3 python3-venv python3-pip \
    pciutils ethtool iproute2 \
    tmux htop \
    chrony \
    build-essential cmake pkg-config \
    libopenblas-dev libssl-dev zlib1g-dev libcurl4-openssl-dev \
    ffmpeg imagemagick

  # RDMA / ConnectX helpers (safe even if you defer fabric tuning)
  apt-get install -y \
    rdma-core ibverbs-providers ibverbs-utils infiniband-diags perftest || true

  if [[ "${INSTALL_DOCKER_DEFAULT}" -eq 1 ]]; then
    # Docker packaging note:
    # - If Docker CE is already installed (common via NVIDIA repos), do NOT try to install Ubuntu's `docker.io`.
    #   Ubuntu's `docker.io` pulls `containerd` which conflicts with CE's `containerd.io`.
    # - If Docker is not installed, default to Ubuntu's `docker.io` + `docker-compose-plugin`.

    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
      Log "Docker CE detected; skipping docker.io install. Ensuring docker-compose-plugin present."
      apt-get install -y docker-compose-plugin
      systemctl enable --now docker || true
    elif dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q "install ok installed"; then
      Log "Ubuntu docker.io detected; ensuring docker-compose-plugin present."
      apt-get install -y docker-compose-plugin
      systemctl enable --now docker || true
    elif command -v docker >/dev/null 2>&1; then
      Log "Docker command already present; ensuring docker-compose-plugin present."
      apt-get install -y docker-compose-plugin
      systemctl enable --now docker || true
    else
      Log "Docker not detected; installing Ubuntu docker.io + docker-compose-plugin."
      apt-get install -y docker.io docker-compose-plugin
      systemctl enable --now docker || true
    fi
  fi

  if [[ "${INSTALL_PODMAN_DEFAULT}" -eq 1 ]]; then
    apt-get install -y podman podman-compose buildah slirp4netns uidmap
  fi

  systemctl enable --now chrony || true
}


EnsureDockerGroup() {
  if [[ "${INSTALL_DOCKER_DEFAULT}" -ne 1 ]]; then
    return 0
  fi

  Log "Ensuring docker group membership for ${SUDO_USER:-root}..."
  if getent group docker >/dev/null; then
    true
  else
    groupadd docker
  fi
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "${SUDO_USER}" || true
  fi
}

CreateVenvFromLock() {
  local venv_path="$1"
  local lock_path="$2"

  Log "Creating venv: ${venv_path}"
  if [[ ! -d "${venv_path}" ]]; then
    python3 -m venv "${venv_path}"
  fi

  # shellcheck disable=SC1090
  source "${venv_path}/bin/activate"
  python -m pip install --upgrade pip

  if [[ -f "${lock_path}" ]]; then
    Log "Installing pip lock: ${lock_path}"
    python -m pip install -r "${lock_path}"
  else
    Log "WARNING: missing lockfile ${lock_path}; skipping install"
  fi

  python -m pip freeze | sort | tee "${OPT_LOG_DIR}/pip.$(basename "${venv_path}").actual.txt" >/dev/null
}

EnsureLlamaBuildScriptPresent() {
  if [[ ! -x "${LLAMA_BUILD_SCRIPT}" ]]; then
    Log "ERROR: llama.cpp build script missing or not executable at:"
    Log "  ${LLAMA_BUILD_SCRIPT}"
    Log "Place build_llamacpp.sh there and chmod +x it, then re-run bootstrap."
    exit 1
  fi
}

BuildLlamacpp() {
  Log "Building + installing llama.cpp via wrapper..."
  EnsureLlamaBuildScriptPresent

  local preset="cuda"
  local uname_s
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"
  [[ "${uname_s}" == "darwin" ]] && preset="metal"

  local sudo_user="${SUDO_USER:-root}"
  sudo -u "${sudo_user}" "${LLAMA_BUILD_SCRIPT}" \
    --src "${LLAMA_SRC}" \
    --build-root "${LLAMA_BUILD}" \
    --prefix "${LLAMA_PREFIX}" \
    --preset "${preset}" \
    --update \
    --jobs "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
}

SyncCompose() {
  Log "Syncing compose stacks..."

  if [[ ! -d "${SEED_DIR}" ]]; then
    Log "WARNING: ${SEED_DIR} missing; skipping compose sync."
    return 0
  fi

  if [[ -d "${SEED_DIR}/compose" ]]; then
    rsync -av --delete "${SEED_DIR}/compose/" "${AI_STACKS}/compose/"
  else
    Log "No ${SEED_DIR}/compose directory found; skipping."
  fi
}

StartComposeStacks() {
  Log "Starting compose stacks (if any)..."

  if [[ ! -d "${AI_STACKS}/compose" ]]; then
    Log "No compose directory; skipping."
    return 0
  fi

  shopt -s nullglob
  for stack_dir in "${AI_STACKS}/compose"/*; do
    if [[ -d "${stack_dir}" ]]; then
      if [[ -f "${stack_dir}/compose.yml" || -f "${stack_dir}/docker-compose.yml" ]]; then
        Log "Bringing up stack: ${stack_dir}"
        (cd "${stack_dir}" && docker compose up -d)
      fi
    fi
  done
}

InstallComfyUI() {
  Log "Installing ComfyUI (checkout + venv)..."

  local sudo_user="${SUDO_USER:-root}"

  if [[ ! -d "${COMFYUI_SRC}/.git" ]]; then
    sudo -u "${sudo_user}" git clone https://github.com/Comfy-Org/ComfyUI "${COMFYUI_SRC}"
  else
    (cd "${COMFYUI_SRC}" && sudo -u "${sudo_user}" git pull --ff-only) || true
  fi

  if [[ ! -d "${COMFYUI_VENV}" ]]; then
    sudo -u "${sudo_user}" python3 -m venv "${COMFYUI_VENV}"
  fi

  # shellcheck disable=SC1090
  source "${COMFYUI_VENV}/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install -r "${COMFYUI_SRC}/requirements.txt"
  python -m pip freeze | sort | tee "${OPT_LOG_DIR}/pip.$(basename "${COMFYUI_VENV}").actual.txt" >/dev/null
}

InstallKokoroTTS() {
  Log "Installing Kokoro TTS venv..."

  local sudo_user="${SUDO_USER:-root}"
  if [[ ! -d "${KOKORO_VENV}" ]]; then
    sudo -u "${sudo_user}" python3 -m venv "${KOKORO_VENV}"
  fi

  # shellcheck disable=SC1090
  source "${KOKORO_VENV}/bin/activate"
  python -m pip install --upgrade pip
  python -m pip install --upgrade numpy soundfile torch
  python -m pip freeze | sort | tee "${OPT_LOG_DIR}/pip.$(basename "${KOKORO_VENV}").actual.txt" >/dev/null
}

SeedModelsViaExternalScript() {
  if [[ "${SEED_MODELS_DEFAULT}" -ne 1 ]]; then
    Log "Skipping model seeding (disabled)."
    return 0
  fi

  if [[ ! -x "${SEED_MODELS_SCRIPT}" ]]; then
    Log "WARNING: model seed script not found or not executable:"
    Log "  ${SEED_MODELS_SCRIPT}"
    Log "Skipping model seed step."
    return 0
  fi

  Log "Seeding models via: ${SEED_MODELS_SCRIPT}"
  sudo -u "${ADMIN_USER}" "${SEED_MODELS_SCRIPT}"
}

RunHeartbeats() {
  if [[ "${RUN_HEARTBEATS_DEFAULT}" -ne 1 ]]; then
    Log "Skipping heartbeats (disabled)."
    return 0
  fi

  Log "Running heartbeats..."

  if [[ -d "${VLLM_VENV}" ]]; then
    # shellcheck disable=SC1090
    source "${VLLM_VENV}/bin/activate"
    python -c "import importlib; m=importlib.import_module('vllm'); print('vllm import ok', getattr(m,'__version__',''))"
  else
    Log "vLLM venv not present; skipping vLLM heartbeat."
  fi

  if [[ -d "${COMFYUI_SRC}" && -d "${COMFYUI_VENV}" ]]; then
    # shellcheck disable=SC1090
    source "${COMFYUI_VENV}/bin/activate"
    python -c "import importlib, compileall; importlib.import_module('nodes'); print('ComfyUI import ok'); compileall.compile_dir('${COMFYUI_SRC}', quiet=1)"
  else
    Log "ComfyUI not present; skipping ComfyUI heartbeat."
  fi

  if [[ -d "${KOKORO_VENV}" ]]; then
    # shellcheck disable=SC1090
    source "${KOKORO_VENV}/bin/activate"
    python -c "import torch, numpy, soundfile; print('kokoro deps import ok'); print('cuda', torch.cuda.is_available())"
  else
    Log "Kokoro venv not present; skipping TTS heartbeat."
  fi
}

# Source helper scripts if they exist
if [[ -f "$(dirname "$0")/semver.sh" ]]; then
  source "$(dirname "$0")/semver.sh"
elif [[ -f "$(dirname "$0")/helpers/semver.sh" ]]; then
  source "$(dirname "$0")/helpers/semver.sh"
fi

if [[ -f "$(dirname "$0")/tui.sh" ]]; then
  source "$(dirname "$0")/tui.sh"
elif [[ -f "$(dirname "$0")/helpers/tui.sh" ]]; then
  source "$(dirname "$0")/helpers/tui.sh"
fi

VersionCheck() {
  Log "Running version validation..."
  local components=("python" "cuda")
  # Add actual version checking logic here
}

DetectMissingComponents() {
  local missing=()
  
  # Check for vLLM
  if [[ ! -d "${VLLM_VENV}" ]]; then
    missing+=("vllm")
  fi
  
  # Check for llama.cpp
  if [[ ! -x "${LLAMA_PREFIX}/bin/llama-cli" ]]; then
    missing+=("llama")
  fi
  
  # Check for ComfyUI
  if [[ ! -d "${COMFYUI_SRC}/.git" ]] || [[ ! -d "${COMFYUI_VENV}" ]]; then
    missing+=("comfyui")
  fi
  
  # Check for Kokoro TTS
  if [[ ! -d "${KOKORO_VENV}" ]]; then
    missing+=("kokoro")
  fi
  
  # Check for Whisper
  if [[ ! -d "${AI_TOOLS}/whisper-env" ]]; then
    missing+=("whisper")
  fi
  
  # Check for Dia
  if [[ ! -d "${AI_TOOLS}/dia-env" ]]; then
    missing+=("dia")
  fi
  
  # Return missing list
  printf '%s\n' "${missing[@]}"
}

PromptGreenfieldInstall() {
  local missing_components
  mapfile -t missing_components < <(DetectMissingComponents)
  
  if [[ ${#missing_components[@]} -eq 0 ]]; then
    Log "All components already installed"
    return 0
  fi
  
  Log "Missing components detected: ${missing_components[*]}"
  
  # Build message for TUI
  local component_list=""
  for comp in "${missing_components[@]}"; do
    component_list+="  - ${comp}\n"
  done
  
  if command -v whiptail >/dev/null 2>&1; then
    if whiptail --title "Greenfield Install" \
        --yesno "The following components are not installed:\n\n${component_list}\nInstall them now?" \
        --yes-button "Install All" \
        --no-button "Skip" \
        15 60; then
      
      Log "User approved greenfield install"
      
      # Set feature flags based on what's missing
      for comp in "${missing_components[@]}"; do
        case "$comp" in
          vllm)
            INSTALL_VLLM=1
            ;;
          llama)
            BUILDLLAMADEFAULT=1
            ;;
          comfyui)
            INSTALL_COMFYUI_DEFAULT=1
            ;;
          kokoro)
            INSTALL_TTS_DEFAULT=1
            ;;
          whisper)
            INSTALL_WHISPER_DEFAULT=1
            ;;
          dia)
            INSTALL_DIA_DEFAULT=1
            ;;
        esac
      done
      
      return 0
    else
      Log "User skipped greenfield install; exiting"
      exit 0
    fi
  else
    # No whiptail, just proceed with defaults
    Log "No TUI available; proceeding with install based on feature flags"
    return 0
  fi
}

Main() {
  RequireRoot

  # Greenfield detection (check what's missing on fresh install)
  PromptGreenfieldInstall

  # Check for pending remediations
  if ls "./ai-configuration/remediation_cookies/"*.cookie 1>/dev/null 2>&1; then
    Log "Pending remediations detected:"
    local pending_items=$(ls "./ai-configuration/remediation_cookies/"*.cookie | xargs -n1 basename | sed 's/.cookie$//')
    echo "$pending_items"
    
    # Show TUI prompt if available
    if command -v prompt_remediation >/dev/null 2>&1; then
      prompt_remediation "Found pending remediations for:\n$pending_items\nFix now?"
      case $? in
        0) Log "Proceeding with remediation" ;;
        1) Log "User deferred fixes; continuing with bootstrap" ;;
        *) Log "User cancelled"; exit 1 ;;
      esac
    else
      Log "TUI not available; proceeding with bootstrap"
    fi
  fi

  # Directory skeleton first
  CheckDirSkeleton || true
  ApplyDirSkeletonFixes

  # Switch logging to /opt now that directory skeleton is enforced
  USE_OPT_LOGS=1
  Log "Switched logging to ${OPT_LOG_DIR}"

  # Version validation
  VersionCheck

  # Component Building Section
  Log "Checking build flags:"
  Log "  BUILDLLAMADEFAULT=${BUILDLLAMADEFAULT}"
  Log "  INSTALL_VLLM=${INSTALL_VLLM}"
  Log "  INSTALL_COMFYUI_DEFAULT=${INSTALL_COMFYUI_DEFAULT}"
  Log "  INSTALL_TTS_DEFAULT=${INSTALL_TTS_DEFAULT}"
  Log "  INSTALL_WHISPER_DEFAULT=${INSTALL_WHISPER_DEFAULT}"
  Log "  INSTALL_DIA_DEFAULT=${INSTALL_DIA_DEFAULT}"
  
 # Bootstrap Build Section - Error Handling Patch
# Replace lines 607-677 in bootstrap_spark_node.sh

  if [[ "${BUILDLLAMADEFAULT}" -eq 1 ]] || \
     [[ "${INSTALL_VLLM}" -eq 1 ]] || \
     [[ "${INSTALL_COMFYUI_DEFAULT}" -eq 1 ]] || \
     [[ "${INSTALL_TTS_DEFAULT}" -eq 1 ]] || \
     [[ "${INSTALL_WHISPER_DEFAULT}" -eq 1 ]] || \
     [[ "${INSTALL_DIA_DEFAULT}" -eq 1 ]]; then
    
    Log "Building AI components via unified build system"
    
    # Track build failures (non-fatal)
    local build_failures=()
    
    if [[ "${BUILDLLAMADEFAULT}" -eq 1 ]]; then
      Log "Attempting llama build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component llama"
        if "$(dirname "$0")/helpers/build.sh" --component llama; then
          Log "✓ llama build succeeded"
        else
          Log "✗ llama build failed (exit code: $?)"
          build_failures+=("llama")
        fi
      else
        Log "WARNING: build.sh not found at $(dirname "$0")/helpers/build.sh"
        build_failures+=("llama (build.sh missing)")
      fi
    fi
    
    if [[ "${INSTALL_VLLM}" -eq 1 ]]; then
      Log "Attempting vLLM build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component vllm"
        if "$(dirname "$0")/helpers/build.sh" --component vllm; then
          Log "✓ vLLM build succeeded"
        else
          Log "✗ vLLM build failed (exit code: $?)"
          build_failures+=("vllm")
        fi
      else
        Log "WARNING: build.sh not found"
        build_failures+=("vllm (build.sh missing)")
      fi
    fi

    if [[ "${INSTALL_COMFYUI_DEFAULT}" -eq 1 ]]; then
      Log "Attempting ComfyUI build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component comfyui"
        if "$(dirname "$0")/helpers/build.sh" --component comfyui; then
          Log "✓ ComfyUI build succeeded"
        else
          Log "✗ ComfyUI build failed (exit code: $?)"
          build_failures+=("comfyui")
        fi
      else
        Log "WARNING: build.sh not found"
        build_failures+=("comfyui (build.sh missing)")
      fi
    fi

    if [[ "${INSTALL_TTS_DEFAULT}" -eq 1 ]]; then
      Log "Attempting Kokoro build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component kokoro"
        if "$(dirname "$0")/helpers/build.sh" --component kokoro; then
          Log "✓ Kokoro build succeeded"
        else
          Log "✗ Kokoro build failed (exit code: $?)"
          build_failures+=("kokoro")
        fi
      else
        Log "WARNING: build.sh not found"
        build_failures+=("kokoro (build.sh missing)")
      fi
    fi
    
    if [[ "${INSTALL_WHISPER_DEFAULT}" -eq 1 ]]; then
      Log "Attempting Whisper build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component whisper"
        if "$(dirname "$0")/helpers/build.sh" --component whisper; then
          Log "✓ Whisper build succeeded"
        else
          Log "✗ Whisper build failed (exit code: $?)"
          build_failures+=("whisper")
        fi
      else
        Log "WARNING: build.sh not found"
        build_failures+=("whisper (build.sh missing)")
      fi
    fi
    
    if [[ "${INSTALL_DIA_DEFAULT}" -eq 1 ]]; then
      Log "Attempting Dia build..."
      if [[ -f "$(dirname "$0")/helpers/build.sh" ]]; then
        Log "Running: $(dirname "$0")/helpers/build.sh --component dia"
        if "$(dirname "$0")/helpers/build.sh" --component dia; then
          Log "✓ Dia build succeeded"
        else
          Log "✗ Dia build failed (exit code: $?)"
          build_failures+=("dia")
        fi
      else
        Log "WARNING: build.sh not found"
        build_failures+=("dia (build.sh missing)")
      fi
    fi
    
    # Report build summary
    if [[ ${#build_failures[@]} -gt 0 ]]; then
      Log "Build failures: ${build_failures[*]}"
      Log "Some components failed to build, but continuing with bootstrap"
    else
      Log "All component builds completed successfully"
    fi
  else
    Log "No build flags set; skipping component builds"
  fi

  # Install apt packages if enabled
  if [[ "${INSTALL_APT_DEFAULT}" -eq 1 ]]; then
    InstallApt
    EnsureDockerGroup
  fi

  # Sync compose stacks
  SyncCompose
  
  # Start compose stacks if Docker is installed
  if [[ "${INSTALL_DOCKER_DEFAULT}" -eq 1 ]]; then
    StartComposeStacks
  fi

  # Seed models if script exists
  SeedModelsViaExternalScript

  # Run heartbeats to verify installations
  RunHeartbeats

  Log "Bootstrap complete!"
  Log "Check logs at: ${OPT_LOG_DIR}/bootstrap.log"
}

# Run main function
Main "$@"
