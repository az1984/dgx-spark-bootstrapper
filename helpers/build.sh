#!/usr/bin/env bash
# Unified build dispatcher for DGX components

set -euo pipefail

# Globals
LOGDIR="/opt/ai-tools/logs/builds"
CONFIG_DIR="/opt/ai-configuration/build_configs"

usage() {
  echo "Usage: $0 --component {vllm|llama|kokoro} [--node N]"
  exit 1
}

validate_component() {
  case "$1" in
    vllm|llama|kokoro) return 0 ;;
    *) echo "Invalid component: $1"; return 1 ;;
  esac
}

init_build_env() {
  mkdir -p "$LOGDIR"
  mkdir -p "$CONFIG_DIR"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  LOG_FILE="$LOGDIR/${component}_${timestamp}.log"
}

run_build() {
  local component="$1"
  local node="${2:-1}"
  
  case "$component" in
    vllm)
      echo "Building vLLM for node $node" | tee -a "$LOG_FILE"
      # TODO: Call actual vLLM build script
      ;;
    llama) 
      echo "Building llama.cpp for node $node" | tee -a "$LOG_FILE"
      echo "${LLAMA_BUILD_SCRIPT:?} not implemented yet" | tee -a "$LOG_FILE"
      ;;
    kokoro)
      echo "Building Kokoro TTS for node $node" | tee -a "$LOG_FILE"
      ;;
  esac
}

main() {
  local component node
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component) component="$2"; shift 2 ;;
      --node) node="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  validate_component "${component:?}" || exit 1
  init_build_env
  run_build "$component" "${node:-1}"
}

main "$@"
