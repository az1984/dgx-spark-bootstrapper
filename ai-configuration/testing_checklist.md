# DGX Spark Bootstrapper Testing Checklist

## Pre-Test Setup
- [ ] Copy entire repo to target device
- [ ] Ensure target has:
  - [ ] NetworkManager
  - [ ] whiptail/dialog
  - [ ] Python 3.8+
  - [ ] CUDA toolkit (if testing GPU components)

## Core Functionality Tests
1. **Basic Bootstrap**
   - [ ] Run with no cookies: `./bootstrap_spark_node.sh`
   - [ ] Verify directory structure creation
   - [ ] Check log output in `/opt/ai-tools/logs/bootstrap/`

2. **Cookie System**
   - [ ] Create test cookie: `touch ai-configuration/remediation_cookies/test.cookie`
   - [ ] Run bootstrap and verify:
     - [ ] Detection message appears
     - [ ] TUI prompt shows correct items
     - [ ] Deferral creates no side effects

3. **Version Validation**  
   - [ ] Modify `desired_state/versions.txt` to force mismatch
   - [ ] Verify:
     - [ ] Version check fails appropriately  
     - [ ] Remediation prompt appears
     - [ ] Cookie created on deferral

## Network Tests (on target)
- [ ] Run networking helper manually
- [ ] Verify interface detection
- [ ] Check MAC override persistence
- [ ] Validate NetworkManager profiles

## Logging
- [ ] Confirm all operations log to:
  - `/opt/ai-configuration/logs/`
  - `/var/log/ai-bootstrap/`
