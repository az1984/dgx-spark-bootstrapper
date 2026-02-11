#!/usr/bin/env bash
# Semantic version comparison utilities

compare_versions() {
  local current="$1"
  local required="$2"
  
  awk -v current="$current" -v required="$required" '
  BEGIN {
    split(current, curr, /\./)
    split(required, req, /\./)
    
    # Basic semantic version comparison
    for (i=1; i<=3; i++) {
      if (curr[i] < req[i]) exit 1
      if (curr[i] > req[i]) exit 0
    }
    exit 0
  }'
}

validate_version() {
  local component="$1"
  local current_ver="$2"
  
  local required_ver=$(grep "$component" "./ai-configuration/desired_state/versions.txt" | cut -d'=' -f2)
  compare_versions "$current_ver" "${required_ver#>= }"
}
