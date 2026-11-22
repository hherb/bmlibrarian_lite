# MANTA judging server

A small localhost-only HTTP server around MANTA-4B (a biomedical question-answering model). It judges how relevant
a paper is to a question and what study design it reports, and records every judgement to a SQLite ledger. It
runs on the Mac (Apple GPU, MPS) or on the DGX (CUDA). It is stand-alone: standard library plus MANTA's own
dependencies; it imports nothing from `bmlibrarian_lite`.

## Setup

Python 3.12. Make a virtualenv per machine and install one requirements file.

- **macOS (MPS):** `uv pip install -r requirements-macos.txt`
- **CUDA (the DGX):**
  1. `uv pip install -r requirements-cuda.txt`
  2. `uv pip install --no-deps flash-linear-attention==0.6.0 fla-core==0.6.0`

  The second step is `--no-deps` so the kernel package cannot replace the torch of step 1.

Why torch is not MANTA's 2.6: in torch 2.6 on MPS, `torch.linalg.solve_triangular` is wrong (99.9 % relative
error) when its input has two or more batch dimensions, which is how transformers' Qwen3.5 Gated DeltaNet fallback
calls it. MANTA then returns NaN relevance and wrong designs. torch 2.15.0 is correct and fast. On the DGX, MANTA's
pinned flash-linear-attention 0.4.2 fails against Triton 3.9 and transformers silently falls back to PyTorch, so
0.6.0 is installed instead. The other pins are unchanged. See the "Spike findings" in
`docs/superpowers/specs/2026-11-22-manta-screener-design.md`.

## Download the model

```bash
hf download gevaertlab/MANTA-4B --revision ae0db2a45edc065315001055d172e6b76cf60ba2 --local-dir ~/models/MANTA-4B
cd ~/models/MANTA-4B && shasum -a 256 -c SHA256SUMS
```

The server refuses to start on any other revision unless `--any-revision` is given.

## Run

```bash
python manta_server.py serve [--model ~/models/MANTA-4B] [--device mps|cuda|cpu] [--port 8765] \
    [--ledger ~/.manta_server/ledger.db] [--any-revision]
curl -s 127.0.0.1:8765/health
```

At start-up it loads the model, runs the four-case self-test from `selftest.json` and logs the result and whether
the flash-linear-attention kernel is in use. If the self-test fails the server stays up but answers 503 to
`/v1/judge`. It refuses to start at all when `selftest.json` is missing, empty or lacks a reference value.

`python manta_server.py make-selftest --device cpu` rewrites each case's reference (`expected_score` or `answer`)
from this model. Only run it when the cases change; the committed references came from a CPU run (about 37 s per
item on an M3 Max).

The server binds to 127.0.0.1 only. To reach the DGX from the Mac:

```bash
ssh -N -L 8765:127.0.0.1:8765 dgx
```

## Hardware results (self-test, 2026-11-22)

| Machine | Device | torch | `ready` | `fla_kernel` | One judgement (relevance + design) |
|---|---|---|---|---|---|
| M3 Max | mps | 2.15.0 | true | false | about 0.9 s |
| DGX Spark | cuda | 2.15.0+cu132 | true | true | about 0.16 s |

Both passed the four-case self-test within the 0.05 tolerance.

## Licences

MANTA-4B is Apache 2.0 (`LICENSE` in the model directory). It is built on Qwen3.5-4B, whose licence is in
`LICENSE_base_model` there. Keep both with any copy of the weights.
