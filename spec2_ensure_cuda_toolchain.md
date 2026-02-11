# Spec 2 — Ensure CUDA/Driver Toolchain

## Goal
Make CUDA runtime + toolkit consistent across nodes and validate GPU visibility.

## Ensure state
- `nvidia-smi` succeeds and shows expected driver version
- CUDA toolkit installed at a known path (e.g. `/usr/local/cuda-13.0`)
- `/usr/local/cuda` symlink points to the chosen toolkit version (recommended)
- Key binaries available via absolute paths:
  - `NVIDIA_SMI_BIN=/usr/bin/nvidia-smi` (adjust if different)
  - `NVCC_BIN=/usr/local/cuda/bin/nvcc` (if used)
  - `PTXAS_BIN=/usr/local/cuda/bin/ptxas`

## Checks
- Capture `nvidia-smi` output
- Capture `ptxas --version`
- `ptxas` must accept `-arch=sm_121` on GB10

## Failure modes / actions
- Toolkit mismatch: install/upgrade toolkit and re-point `/usr/local/cuda`
- Missing `ptxas`: ensure toolkit install completed and symlinks are correct
