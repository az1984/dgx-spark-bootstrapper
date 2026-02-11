#!/usr/bin/env bash
# Unified build dispatcher with standardized path handling

source "$(dirname "$0")/common_paths.sh"

usage() {
  echo "Usage: $0 --component {vllm|llama|kokoro} [--node N]"
  exit 1
}

run_component_build() {
  local component="$1"
  local node="$2"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local log_file="$BUILD_LOGS/${component}_${timestamp}.log"

  case "$component" in
    vllm) "$SCRIPT_DIR/build_vllm.sh" --node "$node" ;;
    llama) "$SCRIPT_DIR/build_llamacpp.sh" --node "$node" ;;
    kokoro) "$SCRIPT_DIR/build_kokoro.sh" --node "$node" ;;
    *) echo "Invalid component: $component"; exit 1 ;;
  esac > "$log_file" 2>&1
}

main() {
  [[ $# -ge 2 ]] || usage
  
  mkdir -p "$BUILD_LOGS"
  run_component_build "$@"
}

main "$@"
