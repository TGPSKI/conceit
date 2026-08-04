# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before any
change. The README explains what conceit is and how to use it; this file covers
what you must not break.

`conceit` orchestrates from-source builds of PyTorch, vLLM, and llama.cpp for
Blackwell `sm_120` on CUDA 13.x and Python 3.14. Everything runs through
`make`; the Makefile is the interface, `scripts/` is the implementation.

Repository: `github.com/TGPSKI/conceit`

## Before you build anything

On a machine that has never built here, run `make setup` first — it discovers
the CUDA toolkit and host compiler and proves they compile together, which is
the failure this repo has paid for most often. See
[`.agents/skills/env-intake/SKILL.md`](.agents/skills/env-intake/SKILL.md).

Read [`.agents/skills/build-triage/SKILL.md`](.agents/skills/build-triage/SKILL.md)
first. It is not background reading — it is the procedure. The single highest-value
rule in it: **coordinates before compilation.** Read the target repo's own
instruction files before issuing a build command, because the cost of guessing
wrong is measured in hours of nvcc, not seconds.

## Invariants

1. **Never edit anything under `src/`.** Those are cloned upstream repos, and
   they are gitignored. A fix there is invisible to everyone else and gone on
   the next `clean`. Fix the source, then `make gen-patches` to capture it.

2. **Never hand-edit `patches/**/*.patch`.** They are generated output —
   `git diff` against the source tree's upstream HEAD. Hand-editing makes the
   file disagree with the tree that produced it, which is the exact failure the
   generated-patch workflow exists to prevent.

3. **Source `scripts/cuda-env.sh` before any build.** The Makefile does it for
   you. An unset `TORCH_CUDA_ARCH_LIST` compiles every supported arch — roughly
   nine times the nvcc work for a result you cannot use.

4. **Exit 0 is not success.** `uv` can exit 0 while cmake and ninja continue as
   orphans. Verify the artifact, not the return code: import the module, check
   `torch.cuda.is_available()`, look at `.build-status.json`.

5. **Never track a pipeline's PID.** `cmd | tee log &` sets `$!` to tee's PID,
   so a monitor watching it sees zero descendants for the whole build. Redirect
   to a log and background a separate `tail`. If you add process supervision
   anywhere, confirm with `ps -p "$pid" -o comm=` that you have the worker.

6. **`make check` must pass before any commit.** shellcheck plus `bash -n` over
   every script. Intentional shellcheck exceptions get an inline
   `# shellcheck disable=SCxxxx` with the reason on the same line — never a
   blanket severity drop in `.shellcheckrc`.

## Layout

```
scripts/
  setup.sh                # environment intake — scan, smoke test, write conceit.env
  cuda-env.sh             # every env default; sourced by everything else
  build-upstream.sh       # the orchestrator — presets, preflight, monitor, status
  gen-patches.sh          # export live src/ diffs into patches/
  install-cuda-toolkit.sh # CUDA runfile install behind a gcc-15 shim
patches/<target>/         # generated; committed; replayed by make patch-*
.agents/skills/build-triage/SKILL.md
.agents/skills/env-intake/SKILL.md
conceit.env               # gitignored — this machine's answers, written by make setup
src/                      # gitignored — cloned upstream trees live here
```

## Conventions

- **Presets** live in the `case "$preset"` block of `build-upstream.sh`. A
  preset sets `build_cmd`, `prebuild_cmd`, `build_dist_cmd`, and the pip dep
  lists. Add new targets there, not in the Makefile.
- **`.build-status.json`** is written atomically (`tmp` → `mv`) so a reader
  never sees a half-written file. Phases: `init → clone → venv → prebuild →
  build_start → building → build_done → wheel → done`, or `failed`. Anything
  interpolated into it goes through `json_escape`. It lives inside the source
  tree, so on a first build nothing is written until the clone lands — `init`
  and `clone` only show up on a re-run. Emitting it is best-effort by design:
  a status write must never take down a build that has been running for hours.
- **Every env var takes the form `${VAR:-default}`**, so any single value can be
  overridden without editing a file. Keep it that way. `conceit.env` (written by
  `make setup`, gitignored) is sourced first and uses the same form, so precedence
  reads: exported by hand > this machine's intake > the defaults in `cuda-env.sh`.
- **Discover the machine, do not assume it.** A hardcoded path is what lets
  `check-env` pass on a host that cannot compile. `scripts/setup.sh` scans for
  toolkits and compilers and then *compiles a CUDA translation unit* with the pair
  it picked — the only evidence that outranks a version comparison. New
  prerequisites belong in that scan, not in a new hardcoded default.
- **Paths derive from the repo root**, computed from the script's own location.
  Never reintroduce a hardcoded `$HOME/...` path — it breaks every clone that
  isn't yours.
- **Makefile recipes need bash** (`SHELL` is set at the top). Recipes use
  `source`, which does not exist in dash.

## Changing things

| Change | Do this |
|---|---|
| Script behaviour | Edit `scripts/`, run `make check`, verify against a real build |
| An upstream fix | Fix it in `src/`, `make gen-patches`, commit the `.patch` |
| A new build target | Add a preset in `build-upstream.sh`, then a thin `make` target |
| Anything in `patches/` | You almost certainly meant to change `src/` instead |

Don't open a PR touching build logic without a build log attached.
