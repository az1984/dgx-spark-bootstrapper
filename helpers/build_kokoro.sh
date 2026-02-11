#!/usr/bin/env bash
# Kokoro TTS builder - called from build.sh dispatcher

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
}

ensure_venv() {
  local venv_path="/opt/ai-tools/kokoro-env-$1"
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    pip install --upgrade pip
  else
    source "$venv_path/bin/activate"
  fi
}

install_dependencies() {
  pip install --upgrade numpy soundfile torch
  pip install git+https://github.com/kokoro-ai/kokoro-tts.git
}

build_kokoro() {
  local node_id="$1"
  local log_file="/opt/ai-tools/logs/builds/kokoro_$(date +%Y%m%d_%H%M%S).log"
  
  local version_req=$(grep "kokoro" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2)
  
  {
    echo "=== Starting Kokoro TTS installation ==="
    ensure_venv "$node_id"
    validate_dependencies || return 1

    install_dependencies

    local installed_ver=$(python -c "from kokoro_tts import __version__; print(__version__)" 2>/dev/null || echo "0.0.0")
    if ! validate_version "$installed_ver" "$version_req"; then
      echo "ERROR: Version mismatch (installed $installed_ver, required $version_req)"
      return 1
    fi
    
    echo "=== Kokoro TTS installation successful ==="
    echo "Version: $installed_ver"
    echo "Virtualenv: $(which python)"
  } | tee "$log_file"
}

build_kokoro "$@"
