#!/usr/bin/env bash
# Standardized path configuration for all DGX helpers

set -euo pipefail

# Base directories
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR="$(dirname "$SCRIPT_DIR")"
export AI_TOOLS="/opt/ai-tools"
export AI_CONFIG="/opt/ai-configuration"

# Log directories
export BUILD_LOGS="$AI_TOOLS/logs/builds"
export NETWORK_LOGS="$AI_TOOLS/logs/networking"
