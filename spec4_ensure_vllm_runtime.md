# Spec 4 — Ensure vLLM Runtime Readiness

## Goal
Confirm vLLM can import, compile kernels, and start a minimal server on each node.

## Ensure state
- `import vllm` works under venv python
- Torch sees CUDA and the GB10 device
- A smoke-test kernel compile succeeds (Triton/torch compile path)

## Checks
- Import test using `VLLM_PY_BIN`
- Validate `torch.cuda.is_available()` and device name
- Optional: `vllm serve --help` or a minimal dry-run config
