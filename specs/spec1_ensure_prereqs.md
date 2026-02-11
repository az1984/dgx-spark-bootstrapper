# Spec 1 — Ensure Prereqs (Base OS tooling)

## Goal
Guarantee baseline packages, services, and kernel settings needed by the rest of the bootstrap.

## Inputs
- Run locally on each node as root
- Optional flags: `--dry-run`, `--verbose`

## Ensure state
- APT updated successfully
- Core tools installed: `git`, `curl`, `jq`, `python3-venv`, `build-essential`, `ninja-build`, `pkg-config`
- Time sync enabled (`systemd-timesyncd` or `chrony`)
- Networking tools present: `iproute2`, `ethtool`, `rdma-core` (if using RoCE)

## Checks
- Print OS version, kernel, hostname, IPs
- Verify required binaries exist (prefer absolute paths when known)
- Exit non‑zero on missing prereqs (unless `--dry-run`)

## Outputs
- A structured report section suitable for troubleshooting logs
