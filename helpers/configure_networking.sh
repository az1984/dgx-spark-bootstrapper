#!/usr/bin/env bash
# DGX Spark Networking Configuration Helper
#
# Configures network interfaces for DGX Spark cluster:
# 1. Interface detection (LAN vs fabric)
# 2. MAC override (02:BB pattern for fabric)
# 3. NetworkManager profile setup
# 4. Error handling and logging

set -euo pipefail

# ============================================================================
# Global Variables
# ============================================================================

LOG_DIR="/opt/ai-tools/logs/networking"                       # Log directory
CONF_DIR="/opt/ai-configuration/networking"                   # Configuration directory
LOG_FILE="${LOG_DIR}/network_config_$(date +%Y%m%d_%H%M%S).log"  # Timestamped log file

LAN_IFACE=""                                                  # LAN interface (set by detection)
FABRIC_IFACE=""                                               # Fabric interface (set by detection)

# ============================================================================
# Utility Functions
# ============================================================================

# Log - Write timestamped log message
#
# Arguments: All message components ($@)
# Outputs: Timestamped message to stdout and log file
# Returns: 0 (always succeeds)
# Globals: Reads LOG_FILE
Log() {
  echo "[$(date +'%FT%T')] $*" | tee -a "$LOG_FILE"
}

# ValidateNetworkTools - Check for required network utilities
#
# Arguments: None
# Outputs: Error messages via Log if tools missing
# Returns: 0 if all tools present, 1 if any missing
# Globals: None
ValidateNetworkTools() {
  local tools=(nmcli ip ethtool)  # Required network utilities
  local tool=""                   # Current tool being checked
  
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      Log "Missing required network tool: $tool"
      return 1
    fi
  done
  
  return 0
}

# DeriveFabricMAC - Generate fabric MAC from interface MAC
#
# Arguments:
#   $1 - iface (string)
# Outputs: Derived MAC address (02:BB:...) to stdout
# Returns: 0 (always succeeds)
# Globals: None
DeriveFabricMAC() {
  local iface="$1"                # Interface name
  local base_mac=""               # Current MAC address
  
  base_mac=$(ip link show "$iface" | awk '/ether/ {print $2}')
  
  # Use 02:BB prefix, keep remaining bytes
  echo "02:BB:${base_mac:6}"
}

# DetectInterfaces - Identify LAN and fabric interfaces
#
# Arguments: None
# Outputs: Detection results via Log
# Returns: 0 (always succeeds)
# Globals: Sets LAN_IFACE, FABRIC_IFACE
DetectInterfaces() {
  # Priority: Ethernet with link UP, exclude loopback and docker
  LAN_IFACE=$(ip -o link show | awk '/state UP/ && !/loopback|docker/ {print $2}' | cut -d':' -f1 | head -1)
  
  # Fabric interface: first ethernet interface that's not LAN
  FABRIC_IFACE=$(ip -o link show | grep -v "$LAN_IFACE" | awk '/ether/ {print $2}' | cut -d':' -f1 | head -1)
  
  export LAN_IFACE FABRIC_IFACE
  
  Log "Detected LAN interface: ${LAN_IFACE:-none}"
  Log "Detected fabric interface: ${FABRIC_IFACE:-none}"
}

# ApplyMACOverride - Set MAC address on interface
#
# Arguments:
#   $1 - iface (string)
#   $2 - new_mac (string)
# Outputs: Status messages via Log
# Returns: 0 (always succeeds with set -e)
# Globals: Reads CONF_DIR
ApplyMACOverride() {
  local iface="$1"                # Interface name
  local new_mac="$2"              # Target MAC address
  local orig_mac=""               # Original MAC address
  
  # Store original MAC for recovery
  orig_mac=$(ip -o link show dev "$iface" | awk '{print $17}')
  mkdir -p "$CONF_DIR"
  echo "$orig_mac" > "$CONF_DIR/${iface}_original.mac"

  # Apply new MAC if different
  if [[ "$(ip -o link show dev "$iface" | awk '{print $17}')" != "$new_mac" ]]; then
    ip link set dev "$iface" down
    ip link set dev "$iface" address "$new_mac"
    ip link set dev "$iface" up
    Log "MAC override applied to $iface: ${orig_mac} → ${new_mac}"
  else
    Log "MAC address already set correctly on $iface ($new_mac)"
  fi
}

# CreateNMProfile - Create NetworkManager connection profile
#
# Arguments:
#   $1 - iface (string)
#   $2 - mac (string)
# Outputs: Profile creation output via Log
# Returns: 0 (always succeeds with set -e)
# Globals: None
CreateNMProfile() {
  local iface="$1"                # Interface name
  local mac="$2"                  # MAC address for profile
  local profile="spark_${iface}" # Connection profile name
  
  # Check if profile already exists - delete old duplicates
  if nmcli connection show "$profile" >/dev/null 2>&1; then
    Log "Profile $profile already exists, removing old instances..."
    # Delete ALL connections with this name (handles duplicates)
    nmcli connection show | grep "^$profile " | awk '{print $2}' | while read -r uuid; do
      nmcli connection delete uuid "$uuid" 2>/dev/null || true
      Log "Deleted old profile instance: $uuid"
    done
  fi
  
  nmcli connection add \
    type ethernet \
    con-name "$profile" \
    ifname "$iface" \
    connection.interface-name "$iface" \
    ethernet.cloned-mac-address "$mac" \
    ipv4.method auto \
    ipv6.method ignore
  
  nmcli connection up "$profile"
  Log "Created NetworkManager profile: $profile"
}

# ============================================================================
# Main Execution
# ============================================================================

# CoreExec - Main execution function
#
# Arguments: All command-line args ($@) (currently unused)
# Outputs: Configuration progress via Log
# Returns: Exits on error, 0 on success
# Globals: Uses LAN_IFACE, FABRIC_IFACE
CoreExec() {
  local fabric_mac=""             # Derived fabric MAC address
  
  mkdir -p "$LOG_DIR"
  
  ValidateNetworkTools || exit 1
  
  Log "Starting network configuration"
  DetectInterfaces
  
  if [[ -z "${LAN_IFACE:-}" ]]; then
    Log "ERROR: No suitable LAN interface found"
    exit 1
  fi

  if [[ -n "${FABRIC_IFACE:-}" ]]; then
    fabric_mac=$(DeriveFabricMAC "$FABRIC_IFACE")
    ApplyMACOverride "$FABRIC_IFACE" "$fabric_mac"
    CreateNMProfile "$FABRIC_IFACE" "$fabric_mac"
  else
    Log "No additional interface found for fabric network"
  fi
  
  Log "Network configuration complete"
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
