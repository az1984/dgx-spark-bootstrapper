# Spec 5 — Ensure PTXAS for sm_121 (GB10)

## Goal
Avoid Triton vendored `ptxas` limitations by forcing a known-good toolkit `ptxas` (CUDA 13.x) for sm_121.

## Observed on Node 1
- Triton vendored `ptxas` is CUDA 12.8 and fails `-arch=sm_121`
- System CUDA 13.0 `ptxas` succeeds

## Ensure state
- Select: `PTXAS_BIN=/usr/local/cuda/bin/ptxas` (CUDA 13.x)
- In launcher environment export:
  - `PTXAS_BIN`
  - `TRITON_PTXAS_PATH=$PTXAS_BIN` (if respected by your Triton build)
  - `PATH=/usr/local/cuda/bin:$PATH` as secondary fallback (but still validate absolute path)
- Validate by compiling a tiny PTX with `-arch=sm_121`

## Checks
- `"$PTXAS_BIN" --version`
- Compile test returns success
