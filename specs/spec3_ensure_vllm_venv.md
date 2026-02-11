# Spec 3 — Ensure Python venv + Wheels

## Goal
Create/repair `/opt/ai-tools/vllm-env` and ensure wheel set is consistent across nodes.

## Ensure state
- Venv exists and contains:
  - Python 3.12.x
  - `pip` up to date
- Required wheels installed and reported:
  - `torch`, `triton`, `vllm` (plus your required extras)

## Checks
- Absolute paths:
  - `VLLM_VENV_DIR=/opt/ai-tools/vllm-env`
  - `VLLM_PY_BIN=$VLLM_VENV_DIR/bin/python`
  - `VLLM_PIP_BIN=$VLLM_VENV_DIR/bin/pip`
- Capture `pip show vllm triton torch` output
- Enforce parity strategy (pick one):
  - pinned `requirements.txt`
  - lockfile (`pip-tools`)
  - offline wheelhouse mirror
