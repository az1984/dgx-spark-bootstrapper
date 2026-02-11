# Spec 6 — Ensure Launchers + Puppet-esque Ensure-State Checker

## Goal
Standardize launcher scripts (ray + vLLM) to use absolute paths and fail fast. Provide a reusable “ensure-state” checker you can run anytime.

## Global variables convention
Define at top of scripts:
- `RAY_BIN=/opt/ai-tools/vllm-env/bin/ray`
- `VLLM_BIN=/opt/ai-tools/vllm-env/bin/vllm`
- `PY_BIN=/opt/ai-tools/vllm-env/bin/python`
- `PIP_BIN=/opt/ai-tools/vllm-env/bin/pip`
- `PTXAS_BIN=/usr/local/cuda/bin/ptxas`
- `NVIDIA_SMI_BIN=/usr/bin/nvidia-smi`
(Adjust to actual paths; validate all with `[[ -x ... ]]`.)

## Ensure-state checker behavior
- For each `_BIN`:
  - verify exists + executable
  - print resolved path (`readlink -f`)
  - capture `--version` when supported
- Verify GPU:
  - `"$NVIDIA_SMI_BIN"` succeeds
- Verify venv:
  - `"$PY_BIN" -V`
  - `"$PIP_BIN" show vllm triton torch`
- Verify ptxas:
  - compile tiny PTX for `sm_121`

## Bootstrapper sections likely rerunnable (idempotent)
- Prereqs installs
- CUDA/toolkit enforcement (`/usr/local/cuda` symlink, binaries)
- Venv/wheels (recreate if empty or mismatched)
- Launchers rewrite + permissions
- Health checks (always safe; run last)

## Output
- One summary block per ensure step with PASS/FAIL and actionable errors
