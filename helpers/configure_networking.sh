#!/usr/bin/env bash
# DGX Spark Networking Configuration Helper
# Implements the following features:
# 1. Interface detection
# 2. MAC override (02:BB pattern)
# 3. NetworkManager profile setup
# 4. Error handling and logging

set -euo pipefail

LOGDIR="/opt/ai-tools/logs/networking"
CONF_DIR="/opt/ai-configuration/networking"
LOG_FILE="${LOGDIR}/network_config_$(date +%Y%m%d_%H%M%S).log"

Log() {
  echo "[$(date +'%FT%T')] $*" | tee -a "$LOG_FILE"
}

validate_network_tools() {
  local tools=(nmcli ip ethtool)
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" >/dev/null; then
      Log "Missing required network tool: $tool"
      return 1
    fi
  done
}

derive_fabric_mac() {
  local iface="$1"
  local base_mac=$(ip link show "$iface" | awk '/ether/ {print $2}')
  echo "02:${base_mac:3:8}"
}

detect_interfaces() {
  # Priority: Ethernet with link, then first UP interface
  LAN_IFACE=$(ip -o link show | awk '/state UP/ && !/loopback|docker/ {print $2}' | cut -d':' -f1 | head -1)
  FABRIC_IFACE=$(ip -o link show | grep -v "$LAN_IFACE" | awk '/ether/ {print $2}' | cut -d':' -f1 | head -1)
  export LAN_IFACE FABRIC_IFACE
}

apply_mac_override() {
  local iface="$1"
  local new_mac="$2"
  
  # Store original MAC
  local orig_mac=$(ip -o link show dev "$iface" | awk '{print $17}')
  mkdir -p "$CONF_DIR"
  echo "$orig_mac" > "$CONF_DIR/${iface}_original.mac"

  # Apply new MAC
  if [[ "$(ip -o link show dev "$iface" | awk '{print $17}')" != "$new_mac" ]]; then
    ip link set dev "$iface" down
    ip link set dev "$iface" address "$new_mac"
    ip link set dev "$iface" up
    Log "MAC override applied to $iface: ${orig_mac} → ${new_mac}"
  else
    Log "MAC address already set correctly on $iface ($new_mac)"
  fi
}

create_nm_profile() {
  local iface="$1"
  local mac="$2"
  local profile="spark_${iface}"
  
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

main() {
  mkdir -p "$LOGDIR"
  validate_network_tools || exit 1
  
  Log "Starting network configuration"
  detect_interfaces
  
  if [[ -z "${LAN_IFACE:-}" ]]; then
    Log "ERROR: No suitable LAN interface found"
    exit 1
  fi

  if [[ -n "${FABRIC_IFACE:-}" ]]; then
    local fabric_mac=$(derive_fabric_mac "$FABRIC_IFACE")
    apply_mac_override "$FABRIC_IFACE" "$fabric_mac"
    create_nm_profile "$FABRIC_IFACE" "$fabric_mac"
  else
    Log "No additional interface found for fabric network"
  fi
}

main "$@"
