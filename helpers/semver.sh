#!/usr/bin/env bash
# Semantic version comparison utilities
#
# Provides version comparison and validation functions for component builds.
# Sourced by component builders, not executed directly.

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

VERSIONS_FILE="/opt/ai-configuration/desired_state/versions.txt"  # Version requirements

# ============================================================================
# Functions
# ============================================================================

# CompareVersions - Compare two semantic versions
#
# Arguments:
#   $1 - current version (string, format: X.Y.Z)
#   $2 - required version (string, format: X.Y.Z)
# Outputs: None
# Returns: 0 if current >= required, 1 if current < required
# Globals: None
CompareVersions() {
  local current="$1"   # Current installed version
  local required="$2"  # Required minimum version
  
  awk -v current="$current" -v required="$required" '
  BEGIN {
    split(current, curr, /\./)
    split(required, req, /\./)
    
    # Compare major, minor, patch in order
    for (i=1; i<=3; i++) {
      if (curr[i] < req[i]) exit 1  # Current version too old
      if (curr[i] > req[i]) exit 0  # Current version newer
    }
    exit 0  # Versions are equal
  }'
}

# ValidateVersion - Validate installed version meets requirements
#
# Arguments:
#   $1 - current version (string)
#   $2 - required version spec (string, may include ">=" prefix)
# Outputs: None
# Returns: 0 if version valid, 1 if insufficient
# Globals: None
ValidateVersion() {
  local current_ver="$1"   # Currently installed version
  local required_spec="$2" # Required version spec (may have ">=" prefix)
  local required_ver=""    # Cleaned required version
  
  # Strip ">=" prefix if present
  required_ver="${required_spec#>= }"
  
  # Special case: "latest" always passes
  if [[ "$required_spec" == "latest" ]]; then
    return 0
  fi
  
  CompareVersions "$current_ver" "$required_ver"
}

# LoadVersionRequirement - Load version requirement for a component
#
# Arguments:
#   $1 - component name (string)
# Outputs: Version requirement to stdout, "latest" if not found
# Returns: 0 (always succeeds)
# Globals: Reads VERSIONS_FILE
LoadVersionRequirement() {
  local component="$1"     # Component name to look up
  local requirement=""     # Version requirement from file
  
  if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "latest"
    return 0
  fi
  
  requirement=$(grep "^${component}=" "$VERSIONS_FILE" | cut -d'=' -f2 || echo "latest")
  echo "$requirement"
}

# CoreExec - No-op for sourced library
#
# Arguments: None
# Outputs: None
# Returns: 0 (always succeeds)
# Globals: None
CoreExec() {
  # This is a library script, nothing to execute
  return 0
}

# ============================================================================
# Entry Point
# ============================================================================

# If executed directly (not sourced), show usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cat <<'USAGE'
semver.sh - Semantic version comparison library

This script is meant to be sourced, not executed directly.

Usage in component builders:
  source "$(dirname "$0")/semver.sh"
  
  if ValidateVersion "$installed" "$required"; then
    echo "Version OK"
  else
    echo "Version too old"
  fi

Functions provided:
  CompareVersions <current> <required>
  ValidateVersion <current> <required_spec>
  LoadVersionRequirement <component>

Example:
  CompareVersions "1.2.3" "1.2.0"  # Returns 0 (1.2.3 >= 1.2.0)
  CompareVersions "1.1.9" "1.2.0"  # Returns 1 (1.1.9 < 1.2.0)
  
  ValidateVersion "0.6.5" ">= 0.6.0"  # Returns 0
  
  req=$(LoadVersionRequirement "vllm")  # Returns "0.6.0" or "latest"
USAGE
  exit 0
fi
