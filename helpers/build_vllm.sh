#!/usr/bin/env bash
# vLLM builder - called from build.sh dispatcher

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
  local venv_path="/opt/ai-tools/vllm-env-$1"
  if [[ ! -d "$venv_path" ]]; then
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    pip install --upgrade pip
  else
    source "$venv_path/bin/activate"
  fi
}

build_vllm() {
  local node_id="$1"
  local version_req=$(grep "vllm" "/opt/ai-configuration/desired_state/versions.txt" | cut -d'=' -f2)
  
  ensure_venv "$node_id"
  validate_dependencies || return 1

  if [[ -d "/opt/ai-tools/src/vllm" ]]; then
    cd "/opt/ai-tools/src/vllm"
    git pull
  else
    git clone https://github.com/vllm-project/vllm.git "/opt/ai-tools/src/vllm"
    cd "/opt/ai-tools/src/vllm"
  fi

  pip install -r requirements.txt
  pip install --no-build-isolation .

  # Verify installed version matches requirements
  local installed_ver=$(python -c "import vllm; print(vllm.__version__)")
  if ! validate_version "$installed_ver" "$version_req"; then
    echo "Version mismatch: installed $installed_ver, wanted $version_req"
    return 1
  fi
}

build_vllm "$@"
