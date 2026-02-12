DGX Spark Bootstrapper – Persistent Networking Section (NODE-based)
==============================================================

Purpose
-------
Provide a concrete, implementation-ready outline for adding a "persist networking fixes"
feature to the DGX Spark bootstrapper.

Goals (what this feature ensures)
---------------------------------
1) Wired LAN (Realtek r8127; typically enP7s7)
   - DHCP via NetworkManager
   - Preferred default route (lower metric than Wi-Fi)
   - Uses the UniFi-reserved MAC (do not change LAN MAC)

2) Fabric / NCCL network (Mellanox ConnectX-7; typically enp1s0f0np0)
   - Static IPv4 on 10.10.10.x/24 (derived from NODE)
   - Never becomes default route
   - Effective MAC is overridden to a locally-administered MAC to avoid duplicate-MAC ambiguity

3) Wi-Fi (backup path for SSH/NRD)
   - Never modified by this feature
   - Optional: report/validate expected Wi-Fi IP if connected

Node-based IP plan (defaults)
-----------------------------
User's environment uses parallel IPs:

  NODE=1:
    Wired: 192.168.2.42
    Wi-Fi: 192.168.3.42
    Fabric: 10.10.10.1

  NODE=2:
    Wired: 192.168.2.43
    Wi-Fi: 192.168.3.43
    Fabric: 10.10.10.2

General rule:
  LAN_HOST = 41 + NODE
  WIRED_EXPECTED_IP = 192.168.2.${LAN_HOST}
  WIFI_EXPECTED_IP  = 192.168.3.${LAN_HOST}   (informational only)
  FABRIC_IP         = 10.10.10.${NODE}

Do not statically configure WIRED_EXPECTED_IP; rely on UniFi reservation + DHCP.
Do statically configure FABRIC_IP.

CLI / Config Inputs
-------------------
Required (unless explicit IP overrides are supplied):
  --node N

Optional network plan overrides:
  --lanSubnet "192.168.2.0/24"        (default)
  --wifiSubnet "192.168.3.0/24"       (default; informational only)
  --fabricSubnet "10.10.10.0/24"      (default)
  --fabricIp "10.10.10.X"             (override derived FABRIC_IP)
  --wiredExpectedIp "192.168.2.X"     (override derived WIRED_EXPECTED_IP; validation only)
  --wiredRouteMetric 100              (default 100)
  --wifiRouteMetric 600               (do not set by default; only read/compare)
  --noFabricMacOverride               (skip MAC override, if needed)
  --fabricMacOverride "02:bb:..."     (optional explicit locally-administered MAC)

Behavior summary
----------------
- Detect LAN and FABRIC interfaces by PCI vendor/model (do not hardcode names).
- Persist a systemd .link rule to override the FABRIC effective MAC (not permanent MAC).
- Ensure NetworkManager profiles exist:
    - lan-wired: DHCP on LAN_IFACE, metric=WIRED_ROUTE_METRIC, autoconnect
    - fabric10: static on FABRIC_IFACE, ipv4.never-default yes, autoconnect
- Never change Wi-Fi configuration.
- Validate/report:
    - LAN_IFACE got a DHCP lease matching WIRED_EXPECTED_IP (warn if mismatch)
    - FABRIC_IFACE has FABRIC_IP
    - Default route prefers wired (if wired is up)
    - Wi-Fi remains present as fallback (optional: report its IP and metric)

Implementation outline (functions + exact commands)
---------------------------------------------------

Function: ConfigureNetworkingPersistent(node, overrides)
-------------------------------------------------------
High-level orchestration:
  1) RequireRootOrExit
  2) RequireCommandsOrExit: udevadm, nmcli, systemctl, ip, tee
  3) DetectInterfaces() -> LAN_IFACE, FABRIC_IFACE, FABRIC_PCI_PATH
  4) ComputeNodePlan(node, overrides) -> WIRED_EXPECTED_IP, WIFI_EXPECTED_IP, FABRIC_IP
  5) PersistFabricMacOverride(FABRIC_PCI_PATH, FABRIC_IFACE, derived_mac)   (unless disabled)
  6) DisableDhcpCdIfPresent()   (avoid fighting DHCP clients)
  7) EnsureLanNmProfile(LAN_IFACE, wired_metric)
  8) EnsureFabricNmProfile(FABRIC_IFACE, FABRIC_IP)
  9) ActivateProfiles(LAN_IFACE, FABRIC_IFACE)
 10) ValidateAndReport(LAN_IFACE, FABRIC_IFACE, WIRED_EXPECTED_IP, WIFI_EXPECTED_IP)

----------------------------------------------------------------

Function: DetectInterfaces()
---------------------------
Goal:
  Identify LAN_IFACE = Realtek r8127 (10ec:8127)
  Identify FABRIC_IFACE = Mellanox (15b3:1021 ConnectX-7) (or match vendor=15b3 and model contains ConnectX-7)

Implementation approach (shell logic):
  For each iface in /sys/class/net (excluding lo, docker*, veth*, etc):
    props = udevadm info -q property -p /sys/class/net/$iface
    if props contains ID_VENDOR_ID=0x10ec and ID_MODEL_ID=0x8127 -> LAN_IFACE=$iface
    if props contains ID_VENDOR_ID=0x15b3 and (ID_MODEL_FROM_DATABASE contains "ConnectX-7" or ID_MODEL_ID matches expected) -> FABRIC_IFACE=$iface; FABRIC_PCI_PATH=$(extract ID_PATH)

Extract PCI path:
  FABRIC_PCI_PATH = value of ID_PATH (example: "pci-0000:01:00.0")

Fail fast:
  If LAN_IFACE or FABRIC_IFACE missing -> exit with clear message and dump udevadm lines.

----------------------------------------------------------------

Function: ComputeNodePlan(node, overrides)
------------------------------------------
Defaults:
  LAN_HOST = 41 + NODE
  WIRED_EXPECTED_IP = 192.168.2.${LAN_HOST}
  WIFI_EXPECTED_IP  = 192.168.3.${LAN_HOST}
  FABRIC_IP         = 10.10.10.${NODE}

Overrides:
  if --wiredExpectedIp provided, replace WIRED_EXPECTED_IP (validation only)
  if --fabricIp provided, replace FABRIC_IP

Return computed values.

----------------------------------------------------------------

Function: DeriveFabricOverrideMac(lan_mac, node, overrides)
-----------------------------------------------------------
Objective:
  Create a deterministic locally-administered MAC for the FABRIC interface.

Options:
  A) If --fabricMacOverride provided -> use it (validate format, locally-administered bit preferred)
  B) Else derive:
     - Take last 4 bytes of LAN MAC and prefix with 02:bb
     Example:
       LAN MAC: 38:a7:46:67:0e:dd
       FABRIC MAC override: 02:bb:46:67:0e:dd

Validate:
  - Must be 6 octets hex
  - First octet should be 02 (locally administered, unicast)
  - Must differ from LAN MAC

Return derived MAC.

----------------------------------------------------------------

Function: PersistFabricMacOverride(fabric_pci_path, fabric_iface, mac)
---------------------------------------------------------------------
Write a systemd .link rule matching the PCI path (NOT MAC), to avoid ambiguity.

Commands:
  sudo tee /etc/systemd/network/10-fabric-unique-mac.link >/dev/null <<EOF
  [Match]
  Path=${fabric_pci_path}

  [Link]
  MACAddressPolicy=none
  MACAddress=${mac}
  EOF

  sudo udevadm control --reload
  sudo udevadm trigger -c add /sys/class/net/${fabric_iface}

  # Apply now (some drivers require link flap)
  sudo ip link set ${fabric_iface} down
  sudo ip link set ${fabric_iface} up

Verification:
  ip link show ${fabric_iface} should show link/ether = ${mac} and permaddr = original

Note:
  This does not modify the LAN interface MAC.

----------------------------------------------------------------

Function: DisableDhcpCdIfPresent()
----------------------------------
Reason:
  dhcpcd can fight NetworkManager and add IPv4LL routes during DHCP failures.

Commands:
  if systemctl list-unit-files | grep -q '^dhcpcd':
    sudo systemctl stop dhcpcd || true
    sudo systemctl disable dhcpcd || true
    sudo pkill -x dhcpcd || true

Do not uninstall.

----------------------------------------------------------------

Function: EnsureLanNmProfile(lan_iface, metric)
-----------------------------------------------
Create a clean NM profile for wired LAN with DHCP and preferred metric.
Do not touch Wi-Fi profiles.

Suggested profile name: lan-wired

Commands (idempotent pattern):
  # delete known conflicting profiles (optional, safe)
  sudo nmcli con delete "Wired connection 1" 2>/dev/null || true

  # if profile exists, modify; else create
  if nmcli -t -f NAME con show | grep -qx 'lan-wired'; then
      sudo nmcli con modify lan-wired connection.interface-name ${lan_iface}
      sudo nmcli con modify lan-wired ipv4.method auto ipv6.method ignore autoconnect yes
  else
      sudo nmcli con add type ethernet ifname ${lan_iface} con-name lan-wired ipv4.method auto ipv6.method ignore autoconnect yes
  fi

  sudo nmcli con modify lan-wired ipv4.route-metric ${metric} ipv6.route-metric ${metric}

Bring up:
  sudo nmcli con up lan-wired || true

----------------------------------------------------------------

Function: EnsureFabricNmProfile(fabric_iface, fabric_ip)
--------------------------------------------------------
Create NM profile for fabric with static IPv4 and never-default.
Suggested profile name: fabric10

Commands:
  sudo nmcli dev set ${fabric_iface} managed yes

  if nmcli -t -f NAME con show | grep -qx 'fabric10'; then
      sudo nmcli con modify fabric10 connection.interface-name ${fabric_iface}
      sudo nmcli con modify fabric10 ipv4.method manual ipv4.addresses ${fabric_ip}/24 ipv6.method ignore autoconnect yes
  else
      sudo nmcli con add type ethernet ifname ${fabric_iface} con-name fabric10 ipv4.method manual ipv4.addresses ${fabric_ip}/24 ipv6.method ignore autoconnect yes
  fi

  sudo nmcli con modify fabric10 ipv4.never-default yes

Bring up:
  sudo nmcli con up fabric10 || true

----------------------------------------------------------------

Function: ActivateProfiles(lan_iface, fabric_iface)
---------------------------------------------------
Bring both up and avoid race/flap.

Commands:
  sudo nmcli con up lan-wired || true
  sudo nmcli con up fabric10 || true

Optionally:
  sleep 1; re-check addresses

----------------------------------------------------------------

Function: ValidateAndReport(...)
-------------------------------
Checks:
  - LAN_IFACE has IPv4 (DHCP): ip -4 addr show ${LAN_IFACE}
  - If WIRED_EXPECTED_IP provided/derived: compare and WARN if mismatch
  - FABRIC_IFACE has ${FABRIC_IP}: ip -4 addr show ${FABRIC_IFACE}
  - Default routes:
      ip route | head
    Expect:
      default via 192.168.2.1 dev ${LAN_IFACE} metric ${wired_metric}
      default via ... dev wifi metric higher (if Wi-Fi connected)
    Ensure no default via 10.10.10.x

  - MACs:
      ip link show ${LAN_IFACE} | sed -n '1,2p'
      ip link show ${FABRIC_IFACE} | sed -n '1,2p'
    Ensure effective MAC differs.

Report nicely:
  - show computed plan and actual results
  - suggest next diagnostics if DHCP missing:
      journalctl -u NetworkManager -n 80
      tcpdump -ni ${LAN_IFACE} -vv 'port 67 or 68'

----------------------------------------------------------------

Test plan (what to verify on a node)
------------------------------------
1) After running the bootstrapper networking stage:
   - ping node from LAN (e.g., Mac mini -> 192.168.2.X)
   - ping fabric peer (10.10.10.1 <-> 10.10.10.2)

2) Reboot:
   - confirm MAC override persists (fabric iface uses 02:bb:..)
   - confirm default route prefers wired, Wi-Fi remains as backup

3) Failure case:
   - If UniFi uplink/switch disappears, DHCP will fail; script should warn and not modify Wi-Fi.

Notes / guardrails
------------------
- Do not disable Wi-Fi, do not modify Wi-Fi route metrics, do not touch SSID creds.
- Wired is DHCP by design (UniFi reservation controls fixed IP); script validates expected IP.
- Fabric static IP must be correct per node; NODE-based default + override makes this safe.
- Persisting fabric MAC override prevents UniFi/ARP confusion from duplicate burned-in MACs.

End.
