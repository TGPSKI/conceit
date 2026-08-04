# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The first build on a fresh clone always failed.** `emit_status` writes
  `.build-status.json` into the target's source tree, but the `init` phase fires
  before the clone has created that directory — so `make build-pytorch` died
  instantly with `src/pytorch/.build-status.json.tmp: No such file or directory`
  on any checkout that had never been built. Status emission now skips until the
  tree is a git repo, and never fails the build if the write does not land. This
  also unbreaks the case where the destination directory exists but is empty:
  the old code seeded a status file into it, and `git clone` then refused the
  now-non-empty directory.
- **`check-env` passed on a machine that could not compile.** `cuda-env.sh`
  hardcoded `CC=/usr/bin/gcc-15`, and `check-env` printed that path without ever
  testing it — so a host without gcc 15 installed sailed through the gate and
  died in cmake twelve minutes later, after a 1.4 GB clone and a full submodule
  sync (`is not a full path to an existing compiler tool`). The host compiler is
  now probed (`gcc-15`, `gcc-14`, `gcc-13`, then plain `gcc`), and `check-env`
  fails if `CC`/`CXX` are not executable, or if the compiler is newer than the
  cap in the toolkit's own `crt/host_config.h` — which is what a rolling distro
  hands you by default, since CUDA 13.3 stops at gcc 15 and Manjaro is on 16.
- **The pytorch preset was missing two build requirements.** Upstream builds
  through `scikit-build-core` now, and `--no-build-isolation` installs nothing on
  our behalf, so `numpy` and `scikit-build-core` have to be seeded into the venv
  alongside the rest of `[build-system] requires`. Without them the build fails
  at backend import, before a single file compiles.

## [0.1.0] - 2026-08-03

First public release. conceit began as the private build orchestration behind a
working PyTorch 2.14.0a0 + vLLM stack on Blackwell `sm_120` — CUDA 13.3, Python
3.14, gcc-15, both built from source with torchvision and torchaudio compiled
against the local torch wheel. Everything below is what it took to turn that
into something another person can run.

### Added

- **`scripts/build-upstream.sh`** — the orchestrator. Clones, syncs submodules
  with exponential backoff, runs a preflight (kills stale builds by process
  group, reports memory/disk/cpu, surfaces the target repo's build
  instructions), creates the venv, compiles under a recursive process-tree
  monitor, and produces wheels. Presets carry the per-target quirks: vLLM's uv
  invocation with a local-torch override file that keeps `cuda-toolkit` out of
  the dependency graph, PyTorch's `--no-build-isolation`, llama.cpp's cmake
  flags.
- **`.build-status.json`** — machine-readable build state per target, written
  atomically so a reader never catches a half-written file. Phases run
  `init → clone → venv → prebuild → build_start → building → build_done →
  wheel → done`, carrying the current ninja step and a live count of every
  descendant process. Meant to be polled instead of grepping a log.
- **`scripts/cuda-env.sh`** — one place for every default: `CUDA_HOME`,
  `TORCH_CUDA_ARCH_LIST=12.0+PTX`, gcc-15 as the CUDA host compiler, and the
  cuDNN/cuBLASMp/cuDSS staging paths. Every value is `${VAR:-default}`, so any
  single knob is overridable without editing the file.
- **`scripts/gen-patches.sh`** — exports the live diffs under `src/` into
  `patches/`, reporting the upstream ref each one was cut from.
- **`scripts/install-cuda-toolkit.sh`** — runs NVIDIA's runfile installer
  behind a temporary gcc-15 symlink directory, without touching the system
  compiler.
- **`patches/pytorch/local.patch`** — cuDSS 0.8.0 changed
  `cudssMatrixCreateCsr` to take three separate type parameters and split its
  type enum away from `cudaDataType_t`. Verified against pytorch `d9abf9e1053`.
- **`patches/vllm-deps/vllm-flash-attn.patch`** — vllm-flash-attn gates on
  Python 3.9–3.13, so a 3.14 build fails at cmake configure. Verified against
  vllm-flash-attn `b3964b1`.
- **`.agents/skills/build-triage/SKILL.md`** — an abductive-triage
  instantiation for build failures: evidence hierarchy, coordinates-before-
  compilation, and a Step-2 adversarial table that scores each assumption
  against the simplest alternative that makes it wrong. Every row in that table
  cost a real compile.
- **Makefile** — the interface. Core builds, the torchvision/torchaudio matrix
  across both venvs in full-CUDA and python-only variants, patch generation and
  replay, smoke tests, `check-env`, and the quality gates.

### Fixed

- **The progress monitor watched the wrong process for every build ever run.**
  `eval "$cmd" 2>&1 | tee log &` sets `$!` to tee's PID, not the build's, so
  `count_descendants` reported zero active processes and the liveness loop
  tracked tee's lifetime instead of the compile's. Measured before the fix:
  `ps -p $build_pid -o comm=` returns `tee`, descendants `0`. After: the real
  worker, descendants non-zero. The build now redirects to its log with a
  separate backgrounded `tail`. (Exit codes were never wrong here — `pipefail`
  was already returning the build's status — but the monitoring, which is the
  advertised feature, was blind.)
- **`make patch-vllm-deps` could not have worked.** It applied its patch at the
  vLLM repo root, but the patch is cut from
  `.deps/vllm-flash-attn-src/`, which cmake FetchContent populates. Applying it
  failed on hunk 1 every time.
- **Patch application reported success on failure.** The apply loop printed
  `WARN: may already be applied` and exited 0 for any failure, including a
  patch that genuinely no longer applied — the premature-success-on-exit-0
  pattern the triage skill exists to catch. It now distinguishes applied,
  already-applied, and failed, and a failure is a hard error naming the
  regeneration command.
- **Nothing worked outside one specific home directory.** The Makefile and
  every script hardcoded a single absolute path, so a clone anywhere else
  silently built into the wrong tree. All paths now derive from the repo root,
  computed from each script's own location.
- **`MAX_JOBS` was pinned to 20**, which wastes a bigger machine and thrashes a
  smaller one. It derives from `nproc` and stays overridable.
- **`.build-status.json` could emit invalid JSON.** Build commands and repo
  URLs land in the `detail` field unescaped, so a quote or backslash broke the
  file exactly when something interesting was happening. Values are escaped.
- **An interrupted build orphaned its helpers.** The tail and monitor processes
  were only killed on the normal paths; Ctrl-C left both running. A single EXIT
  trap now reaps them.
- **`gen-patches.sh`'s fallback path produced a corrupt patch.** For a source
  tree without `.git`, it diffed against an empty baseline, which lists every
  file in the tree as a new file. There is no way to recover an upstream
  baseline from such a tree, so it now says so and skips.

### Changed

- **Quality gates run over one language.** `install-cuda-toolkit.sh` was zsh
  for no reason beyond how it was first written, which forced a shebang-sniffing
  split in the Makefile, a second linter, and a zsh install in CI. Ported to
  bash; shellcheck now covers every script and CI delegates to `make check` so
  it cannot drift from a local run.
- **Five intentional shellcheck findings carry inline suppressions** with their
  reasons — deliberate word-splitting of package lists, and quotes that must
  survive into an `eval` — rather than lowering the severity floor globally.
- **The Makefile's eight torchvision/torchaudio targets share four canned
  recipes** instead of four copies of the same body, and recipes now run under
  bash explicitly. They use `source`, which does not exist in dash, so every
  build target failed on a Debian or Ubuntu host.
- **cuDNN, cuBLASMp, and cuDSS are located by globbing** their extracted
  archives under `cuda/` rather than by pinned version strings, so an upgrade
  is an extract and nothing else.

### Removed

- **`scripts/build-{pytorch,vllm,llama}.sh`** — three unreferenced wrappers
  holding a second copy of the upstream repo URLs, waiting to disagree with the
  Makefile.
- **`patches/patch-conceit.sh`** — a one-shot personal migration that required
  a file never present in the tree.
