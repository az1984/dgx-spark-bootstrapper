#!/usr/bin/env bash
# Unified build helper dispatcher

set -euo pipefail

source "$(dirname "$0")/semver.sh"
source "$(dirname "$0")/tui.sh"

BUILD_DIR="./ai-configuration/build_logs"
mkdir -p "$BUILD_DIR"

build_component() {
  local component="$1"
  local node="$2"
  local log_file="$BUILD_DIR/${component}_node${node}.log"
  
  case "$component" in
    llama)
      ./helpers/build_llamacpp.sh --node "$node" | tee "$log_file"
      ;;
    vllm)
      ./helpers/build_vllm.sh --node "$node" | tee "$log_file"
      ;;
    *)
      echo "Unknown component: $component"
      return 1
      ;;
  esac
}

# Main execution
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 --component [llama|vllm] --node N"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component)
      COMPONENT="$2"
      shift 2
      ;;
    --node)
      NODE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

