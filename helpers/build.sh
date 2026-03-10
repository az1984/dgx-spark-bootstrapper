#!/usr/bin/env bash
# Unified build dispatcher with standardized path handling

source "$(dirname "$0")/common_paths.sh"

usage() {
  echo "Usage: $0 --component {vllm|llama|kokoro|whisper|dia|comfyui} [--node N]"
  echo ""
  echo "Components:"
  echo "  vllm      - vLLM inference engine"
  echo "  llama     - llama.cpp (CUDA/Metal build)"
  echo "  kokoro    - Kokoro TTS (basic text-to-speech)"
  echo "  whisper   - Whisper ASR (speech-to-text)"
  echo "  dia       - Dia TTS (multi-character audiobook generation)"
  echo "  comfyui   - ComfyUI (image generation)"
  exit 1
}

run_component_build() {
  local component="$1"
  local node="$2"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local log_file="$BUILD_LOGS/${component}_${timestamp}.log"

  case "$component" in
    vllm) "$SCRIPT_DIR/build_vllm.sh" "$node" ;;
    llama) "$SCRIPT_DIR/build_llamacpp.sh" --node "$node" ;;
    kokoro) "$SCRIPT_DIR/build_kokoro.sh" "$node" ;;
    whisper) "$SCRIPT_DIR/build_whisper.sh" "$node" ;;
    dia) "$SCRIPT_DIR/build_dia.sh" "$node" ;;
    comfyui) "$SCRIPT_DIR/build_comfyui.sh" "$node" ;;
    *) echo "Invalid component: $component"; usage ;;
  esac > "$log_file" 2>&1
  
  local exit_code=$?
  
  if [[ $exit_code -eq 0 ]]; then
    echo "✓ $component build completed successfully"
    echo "  Log: $log_file"
  else
    echo "✗ $component build failed (exit code: $exit_code)"
    echo "  Log: $log_file"
    echo ""
    echo "Last 20 lines of log:"
    tail -20 "$log_file"
  fi
  
  return $exit_code
}

main() {
  [[ $# -ge 2 ]] || usage
  
  mkdir -p "$BUILD_LOGS"
  run_component_build "$@"
}

main "$@"
