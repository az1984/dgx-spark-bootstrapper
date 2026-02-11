# Spec 7 — TUI Remediation System

## Goal
Interactive terminal interface for state remediation with yes/no/later choices.

## Components
1. **TUI Engine** (`helpers/tui.sh`)
   - Uses `dialog` or `whiptail`
   - Consistent color scheme (yellow warnings, red errors)
2. **Cookie System**
   - Persistent note files in `/opt/ai-configuration/remediation_cookies/`
   - No expiration; manual cleanup required

## Workflow
```mermaid
sequenceDiagram
    User->>System: Runs bootstrap
    System->>System: Detect state drift
    alt Drift Found
        System->>TUI: Show remediation options
        TUI->>User: [Y]es/[N]o/[L]ater
        User->>System: Records choice
        alt Later
            System->>Filesystem: Create ${component}.cookie
        end
    end
```

## Requirements
- Cookie filenames match component names (e.g., `vllm.cookie`)
- Log all interactions to `/opt/ai-configuration/logs/tui.log`
