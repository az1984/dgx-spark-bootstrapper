# Spec 8 — Build System Requirements

## Core Contracts
1. **Dispatcher** (`build.sh`):
   - Must support `--component` and `--node` params
   - All builds log to `/opt/ai-tools/logs/builds/` 

2. **Version Validation**:
   - Compare against `/opt/ai-configuration/desired_state/versions.txt`
   - Fail fast on version mismatch (exit code 1)

3. **Component Builders**:
   - Must implement `validate_dependencies()`
   - Support `--update` and `--clean` flags
   - Enforce standardized paths (`/opt/ai-tools/...`)

## Required Tools (Preflight Check)
```bash
# All Builders
git cmake python3 pip

# CUDA Builder Only
nvcc
```

## Error States
```mermaid
stateDiagram-v2
    [*] --> PreCheck
    PreCheck --> MissingTools: Required tool not found
    PreCheck --> Build: Tools OK
    Build --> VersionMismatch: Installed ≠ desired
    Build --> Success
