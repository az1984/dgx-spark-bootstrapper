# DGX Spark Bootstrap & Launcher Suite

This repo is a **bootstrapper + ensure-state toolkit** for DGX Spark nodes (single-node and clustered),
plus **launchers** for Ray and vLLM that are intentionally *fail-fast* and *path-explicit*.

## Directory layout

- `specs/`  
  Temporary, iterative specs used to design and implement the repo.  
  **You should expect churn here.**

- `docs/contracts/`  
  Ongoing, stable **source of truth** for interfaces/behavior **once specs are finished**.  
  Contracts evolve over time; specs eventually “graduate” into contracts.

- `scripts/`  
  Executable entrypoints (bootstrapper, ensure-state checkers, launchers).

## Specs (current)

These are the initial “ensure-state” specs that drive what we implement:

1. `specs/spec1_ensure_prereqs.md` — Ensure base OS prereqs + baseline tooling
2. `specs/spec2_ensure_cuda_toolchain.md` — Ensure CUDA toolkit + key binaries present
3. `specs/spec3_ensure_vllm_venv.md` — Ensure vLLM virtualenv exists and is populated
4. `specs/spec4_ensure_vllm_runtime.md` — Ensure runtime environment sanity for vLLM
5. `specs/spec5_ensure_ptxas_sm121.md` — Ensure **ptxas supports `-arch=sm_121`**
6. `specs/spec6_ensure_launchers_state.md` — Ensure launchers are configured and path-explicit

### Key takeaway from the PTXAS investigation

On Node 1, Triton’s vendored `ptxas` (inside the venv) **failed** for `sm_121`, but the **system CUDA 13 `ptxas`**
succeeded. The repo should therefore implement an ensure-state fix that:
- Detects Triton vendored `ptxas` (if present)
- Verifies it can assemble `-arch=sm_121`
- If not, **forces use of the system `ptxas`** from a known CUDA 13 install (absolute path)

## Design principles

- **Absolute paths for key binaries.**  
  Launchers must not rely on `PATH`. Instead define and validate globals like:
  - `RAY_BIN=...`
  - `VLLM_BIN=...` (or the venv python + `-m vllm`)
  - `PTXAS_BIN=...`

- **Fail fast with clear errors.**  
  If a required binary is missing/non-executable, stop immediately with a helpful message.

- **Puppet-esque ensure-state.**  
  We want both:
  - “Check” mode (validate current state; report drift)
  - “Fix” mode (apply corrections deterministically)

- **Non-destructive by default.**  
  Any mutating action should be gated behind an explicit flag (e.g. `--act`).

## Workflow

We use the two-phase `/implement` workflow enforced by `clinerules.md`:

1. **MODE: PLAN** — produce an “Act Packet” only (no file edits, no commands)
2. **MODE: ACT** — execute exactly what the Act Packet says (edits + tests + progress updates)

Progress tracking lives in: `specs/PROGRESS.md`

---

Generated: 2026-02-10
