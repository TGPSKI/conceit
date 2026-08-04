# conceit

[releases](https://github.com/TGPSKI/conceit/releases) | [changelog](CHANGELOG.md) | [triage skill](.agents/skills/build-triage/SKILL.md) | [pate.sh](https://pate.sh)

**Build the GPU inference stack from source, repeatably.** PyTorch, vLLM, and llama.cpp for Blackwell `sm_120` on CUDA 13.x and Python 3.14 — one interface, machine-readable build state, and a triage skill that catches the coordinate mistakes before they cost you a three-hour compile.

No wheel to wait for. No container to inherit. No blog post to follow line by line.

```bash
source scripts/cuda-env.sh
make check-env
make build-pytorch
```

## Why you end up here

Prebuilt wheels are compiled for the architectures the publisher chose. When yours isn't one of them, you get:

```
CUDA error: no kernel image is available for execution on the device
RuntimeError: sm_120 is not compatible with the current PyTorch installation
```

vLLM tracked this for Blackwell in [#35432](https://github.com/vllm-project/vllm/issues/35432) — prebuilt wheels and official images built without SM120/SM121 flags. That issue is now closed, and upstream coverage moves; **check whether a stock wheel works for you before spending an afternoon here.** What doesn't move is the rest of it: no cp314 wheels for torch or vLLM, CUDA 13.3 ahead of what PyPI ships, an arch list you want narrowed to your one GPU, and a patch or two upstream hasn't taken yet. That is the from-source path, and it is the same three to six hours of nvcc every time you re-derive it by hand.

conceit is that path, written down and made repeatable.

## What it does

| | |
|---|---|
| **Orchestrator** | `build-upstream.sh` clones, syncs submodules with backoff, runs preflight, creates the venv, compiles under a process-tree monitor, and produces wheels. Per-target presets encode the quirks: vLLM's uv + local-torch override that keeps `cuda-toolkit` out of the dep graph, PyTorch's `--no-build-isolation`, llama.cpp's cmake flags. |
| **Build state** | `.build-status.json` per target — `init → clone → venv → build_start → build_done → wheel → done`, with the current ninja step and a live count of every descendant process. Poll it instead of grepping logs. |
| **Patches** | Generated from the live source tree, never hand-written. Applying is idempotent; a patch that no longer applies is a hard error, not a warning. |
| **The dual-venv matrix** | torchvision and torchaudio built against *your* torch wheel, into both the pytorch and vllm venvs, with a python-only fast path when you just need the import to resolve. |
| **Triage skill** | An abductive-triage instantiation for build failures. Read it before the first build command, not after the third failure. |

## Patches are generated, never hand-written

A patch you maintain by hand drifts from the tree it patches, silently, until the day it matters. So conceit doesn't keep any. You fix the source, export the diff, and commit what comes out:

```bash
# fix something in src/pytorch, then:
make gen-patches
#   write pytorch: patches/pytorch/local.patch (17 lines, upstream d9abf9e1053)
```

Two ship today, each verified against the upstream commit it was cut from:

| Target | Fix | Verified against |
|---|---|---|
| `pytorch` — `SparseCsrTensorMath.cu` | `CUDA_R_*` → `CUDSS_R_*`, plus the third type param | pytorch `d9abf9e1053` |
| `vllm` — `vllm-flash-attn-src/CMakeLists.txt` | add `"3.14"` to `PYTHON_SUPPORTED_VERSIONS` | vllm-flash-attn `b3964b1` |

`make patch-pytorch` and `make patch-vllm-deps` replay them on a fresh clone. If upstream has moved past the recorded ref, the apply fails loudly and tells you to regenerate.

## The triage skill is the part that saves the afternoon

[`.agents/skills/build-triage/SKILL.md`](.agents/skills/build-triage/SKILL.md) encodes the failure modes as a procedure: an evidence hierarchy (DEFINITIVE `ps`/`import`/`bash -n` > CONFIG > SOCIAL > ANECDOTAL) and one rule — **coordinates before compilation.** Read the target repo's instruction files before issuing the first build command.

Its Step-2 table is the useful part. For everything you assume, it asks what the simplest alternative is that makes you wrong:

| Inference | Simplest alternative | Score |
|---|---|---|
| "Build command is `python setup.py develop`" | CLAUDE.md specifies `pip install -e . -v --no-build-isolation` | **5** |
| "Python 3.14 is supported by all deps" | flash-attn's CMakeLists gates on 3.9–3.13 | **5** |
| "Default CUDA arch list is fine" | Unset compiles 9 arches on a 1-GPU machine; you want `12.0+PTX` | **4** |
| "`$!` captures the worker PID" | In `cmd \| tee file &`, `$!` is tee's — the worker is never tracked | **4** |
| "Build exit 0 means an importable package" | uv can exit 0 while cmake and ninja keep running as orphans | **5** |

Anything scoring 4–5 gets resolved before you compile. Every row cost a real build once.

## Install

```bash
git clone https://github.com/TGPSKI/conceit.git
cd conceit
source scripts/cuda-env.sh   # CUDA_HOME, TORCH_CUDA_ARCH_LIST=12.0+PTX, gcc-15
make check-env               # fails fast on anything missing
```

`make help` lists every target. Nothing is installed system-wide; the source trees and venvs live under `src/` in the checkout.

**Tested on:** Blackwell `sm_120` (RTX PRO 4500), CUDA 13.3, Python 3.14.6 via asdf, gcc/g++ 15, x86_64 Manjaro. Hopper and Ampere work by setting `TORCH_CUDA_ARCH_LIST`. Budget ~200 GB of disk and 32 GB of RAM for parallel nvcc.

**You need:** the CUDA 13.3 toolkit (`scripts/install-cuda-toolkit.sh` handles the gcc-15 shim), `uv`, and — for the full torchvision/torchaudio builds — `libjpeg-turbo libpng ffmpeg sox`.

## Configure

Every knob is an environment variable with a working default, resolved in `scripts/cuda-env.sh`. Export one to override it; nothing needs editing.

```bash
TORCH_CUDA_ARCH_LIST=9.0+PTX   # build for Hopper instead
MAX_JOBS=8                     # defaults to nproc
NVCC_THREADS=2                 # raising this with MAX_JOBS is how you OOM a build
CONCEIT_ROOT=/mnt/big          # put src/ and cuda/ on another disk
CUDA_HOME=/usr/local/cuda-13.2
```

cuDNN, cuBLASMp, and cuDSS are found by globbing `cuda/` for their extracted archives, so upgrading one means extracting the new tarball and nothing else.

## Go deeper

| you want to… | start here | then |
|---|---|---|
| **build** the stack | `make help` — every target, one line each | [AGENTS.md](AGENTS.md) for the invariants · `make env-show` for resolved paths |
| **debug** a failed build | [the triage skill](.agents/skills/build-triage/SKILL.md) — intake, adversarial review, coordinate resolution | `make status` · `.build-status.json` per target |
| **change** something | [CONTRIBUTING.md](CONTRIBUTING.md) — what `make check` gates and why patches are generated | [CHANGELOG.md](CHANGELOG.md) |
| **understand the risk** | [SECURITY.md](SECURITY.md) — the `eval` surface, log exposure, and supply chain, stated plainly | |

## License

GPL-3.0 — see [LICENSE](LICENSE).
