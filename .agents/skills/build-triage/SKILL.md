---
name: build-triage
description: "Investigate and prevent build failures for conceit from-source builds (PyTorch, vllm, llama.cpp). Resolves the most common coordinate mismatches — wrong build command, wrong Python version, unset arch list, wrong PID tracked, premature success declaration — before they cost hours of compile time. Use before starting any build and when a build fails."
metadata:
  author: conceit
  version: "1.0"
compatibility: "bash, uv, cmake, ninja, nvidia-smi, python (asdf-managed)"
---

# conceit Build Triage

Investigate build failures and prevent known coordinate errors for conceit source builds.

## Design Principles

- **Coordinates before compilation**: Read every AI instruction file in the target repo before issuing the first build command. The file wins.
- **Evidence hierarchy**: DEFINITIVE (ps, python -c import, bash -n, file contents) > CONFIG (CLAUDE.md, AGENTS.md, CMakeLists.txt) > SOCIAL (agent explanations, training-data intuitions) > ANECDOTAL ("I think $! captures the worker PID")
- **Reporter methodology ≠ system path**: What the agent assumes the build command is and what CLAUDE.md specifies are independent until proven same.

## Prerequisites

- `cuda-env.sh` sourced: `source $CONCEIT_ROOT/scripts/cuda-env.sh`
- Target repo cloned under `$CONCEIT_ROOT/src/<repo>`
- `nvidia-smi` accessible (confirms GPU compute capability)
- `uv` installed at `~/.local/bin/uv`

---

## Step 1: Intake

Extract ALL facts from the build request into a table before touching the keyboard.

| Tag | Meaning |
|-----|---------|
| **STATED** | Directly quoted from the request or a file on disk |
| **INFERRED** | A conclusion the agent draws from training or context |
| **MISSING** | Required to proceed but not yet confirmed |

```markdown
| Fact | Source | Tag |
|------|--------|-----|
| Target repo and branch | Request | STATED/MISSING |
| Build command to use | ? | MISSING until CLAUDE.md read |
| Python version in use | `python --version` | STATED after check |
| GPU compute capability | `nvidia-smi` | STATED after check |
| TORCH_CUDA_ARCH_LIST value | `echo ${TORCH_CUDA_ARCH_LIST:-UNSET}` | STATED after check |
| Which venv will be used | ? | MISSING until confirmed |
```

**Required extractions** (mark MISSING if not yet confirmed):
- Exact build command (never infer — read it from the repo's instruction file)
- Python version and whether it appears in each dependency's supported-versions list
- GPU compute capability from `nvidia-smi`
- `TORCH_CUDA_ARCH_LIST` value (UNSET is a valid finding, not a pass)
- Which PID the progress monitor will track after the build pipeline starts

---

## Step 2: Adversarial Review

For each **INFERRED** fact: "What is the simplest alternative that makes this wrong?"

For each **MISSING** fact: "Could this single fact resolve the entire issue?" Score 1–5.

**Any MISSING fact scoring 4–5 MUST be resolved before proceeding.**

### Common inferences to challenge in this domain

| Inference | Simplest alternative | Score |
|-----------|---------------------|-------|
| "Build command is `python setup.py develop`" | CLAUDE.md specifies `pip install -e . -v --no-build-isolation` | **5** |
| "Python 3.14 is supported by all deps" | Flash-attn CMakeLists.txt gates on 3.9–3.13 | **5** |
| "Default CUDA arch list is fine" | Unset list compiles for 9 arches on a 1-GPU machine; correct value is `12.0+PTX` for Blackwell | **4** |
| "`$!` captures the worker PID" | In `cmd \| tee file &`, `$!` is tee's PID — worker is never tracked | **4** |
| "Build exit 0 = importable package" | uv can exit 0 while cmake/ninja continue as orphans | **5** |
| "`MAX_JOBS=6` is conservative and safe" | `-l6` load cap on a 20-core machine blocks new jobs even when all cores are idle on I/O | **3** |

---

## Step 3: Coordinate Resolution

### Resolve the Reader (what the agent assumes)

Document exactly what build command, Python version, and arch list the agent intends to use.
This must be stated explicitly — not derived from defaults or training memory.

### Resolve the System Path (what the repo specifies)

```bash
# 1. Read every AI instruction file in the target repo FIRST
cat $CONCEIT_ROOT/src/$REPO/CLAUDE.md  2>/dev/null || true
cat $CONCEIT_ROOT/src/$REPO/AGENTS.md  2>/dev/null || true

# 2. Confirm Python version against each FetchContent dep's allow-list
python --version
grep -r "PYTHON_SUPPORTED_VERSIONS\|python_requires" \
  $CONCEIT_ROOT/src/$REPO/.deps/ 2>/dev/null | head -20

# 3. Confirm GPU arch
nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader

# 4. Confirm arch list
echo "TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-UNSET}"

# 5. Confirm script syntax is clean
bash -n $CONCEIT_ROOT/scripts/build-upstream.sh
```

### Compare (Gate)

```
AGENT intends:  {build command, Python version, arch list, MAX_JOBS}
REPO specifies: {what CLAUDE.md/AGENTS.md says, PYTHON_SUPPORTED_VERSIONS, GPU cc}
```

| Verdict | Outcome |
|---------|---------|
| **Different on any dimension** | `COORDINATE MISMATCH` — correct before starting; skip to Step 7 |
| **All match** | `COORDINATES VERIFIED` — proceed to Step 4 |
| **Any dimension Unknown** | Resolve it; do not proceed |

---

## Step 4: Ground Truth Check

Validate live system state for each coordinate before starting the build.

```bash
# Python is the asdf-managed version (not system python)
which python && python --version

# uv venv will use the right interpreter
~/.local/bin/uv venv --python $(python --version 2>&1 | grep -oP '\d+\.\d+') \
  --dry-run 2>&1 | head -5

# nvidia-smi returns compute_cap matching TORCH_CUDA_ARCH_LIST
nvidia-smi --query-gpu=compute_cap --format=csv,noheader

# No stale build processes from a prior run
pgrep -af "ninja|cmake --build|uv pip install -e" | grep -v grep || echo "clean"
```

```
GROUND TRUTH: {command} → {result}
Confirms/contradicts: {which coordinate}
```

---

## Step 5: Timeline

**Only entered if Step 3 outputs `COORDINATES VERIFIED`.**

Track build phase transitions using `.build-status.json`:

```bash
cat $CONCEIT_ROOT/src/$REPO/.build-status.json 2>/dev/null
```

Build state sources for this domain:

| Phase | Evidence source |
|-------|----------------|
| init / clone / pull | `.build-status.json` `phase` field |
| prebuild (dep install) | Log: `Installed N packages in Xms` |
| cmake configure | Log: `-- CUDA target architectures:` |
| compile | `pgrep -c nvcc`; `ps -o args= -C nvcc \| grep -o 'sm_[0-9]*' \| sort -u` |
| build done | `.build-status.json` `phase: build_done`; `import <pkg>` passes |

Confirm which arch nvcc is actually targeting during compile:

```bash
ps -o args= -C nvcc 2>/dev/null | grep -o '\-gencode arch=[^ ]*' | sort -u
```

---

## Step 6: Hypothesize + Discriminate + Narrow

### Common hypotheses for conceit build failures

| Hypothesis | Prior | Supporting Evidence | Contradicting Evidence | Discriminating Check |
|------------|-------|--------------------|-----------------------|---------------------|
| Wrong build command (CLAUDE.md not read) | **High** | Agent used setup.py or pip install without -e | CLAUDE.md on disk specifies exact command | `cat $REPO/CLAUDE.md` |
| Python version not in dep allow-list | **High** | Python 3.14+; dep has explicit list | Dep installs fine | `grep PYTHON_SUPPORTED_VERSIONS $REPO/.deps/*/CMakeLists.txt` |
| CUDA arch list unset (compiling all arches) | **High** | Build takes 3+ hours; sm_70/80 in ptxas args | `TORCH_CUDA_ARCH_LIST` set | `ps -o args= -C nvcc \| grep -o 'sm_[0-9]*' \| sort -u` |
| build_pid tracking tee not worker | **High** | Progress monitor shows 0 jobs during active compile | `ps -p $build_pid -o comm=` shows worker | `ps -p $build_pid -o pid,comm,ppid=` |
| Build exited 0 before cmake finished | **Medium** | `import pkg` fails; no `.so` files in repo | cmake still in `ps` after script exit | `pgrep -af "cmake --build\|ninja"` |
| Missing build-system dep (no-build-isolation) | **Medium** | `ModuleNotFoundError` for setuptools_rust/cmake | All deps pre-installed in prebuild_cmd | Inspect prebuild_cmd list vs `setup.cfg [build-system]` |
| cuDSS API signature mismatch | **Low** (CUDA 13.x specific) | `error: no match for call to cudssMatrixCreateCsr` | Older CUDA version | `grep -r "cudssMatrixCreateCsr" /usr/local/cuda-*/include/` |

### Discriminate

**Cheapest check**: `cat $REPO/CLAUDE.md` followed by `python -c "import $PKG"` after build.
These two checks collapse the two highest-prior hypotheses in under 5 seconds each.

### Narrow

Execute checks in priority order. Collapse each eliminated hypothesis. Stop at one survivor.

---

## Step 7: Contain

| Situation | Minimum action |
|-----------|---------------|
| Wrong build command | Update the command to match CLAUDE.md; no other action |
| Python not in allow-list | Patch `PYTHON_SUPPORTED_VERSIONS` in `.deps/<dep>/CMakeLists.txt` before build |
| Arch list unset | Add `export TORCH_CUDA_ARCH_LIST="<cc>+PTX"` to `cuda-env.sh`; restart build |
| build_pid = tee | Capture worker PID before the pipe; do not restart until fix is in the script |
| cmake orphaned, import fails | Re-run `uv pip install -e . --no-build-isolation`; uv skips already-built artifacts |
| API signature mismatch | Patch the source file; do not set `USE_<LIB>=0` (cmake cache ignores env overrides) |
| Coordinate mismatch (any) | Correct the coordinate; document in Known Patches table below |

---

## Artifact Checkpoint

**File**: `$CONCEIT_ROOT/src/$REPO/.build-status.json` (machine-readable, updated by build script)

**Session artifact template**:

```markdown
# Build Investigation: {repo} on {date}
Status: {investigating / resolved — coordinate mismatch / resolved — build succeeded}

## Executive Summary
{2-3 sentences}

## Findings

### Finding 1: {title}
**What happened**: ...
**Evidence**:
| Source | Observation | Confidence |
|--------|-------------|------------|
| CLAUDE.md | Build command: `pip install -e . -v --no-build-isolation` | CONFIG |
| Agent | Issued `python setup.py develop` | ANECDOTAL |
| Terminal | `error: no module named ...` | DEFINITIVE |

**Remediation**: {action taken}

## Timeline
| Time | Event | Source |
|------|-------|--------|

## Open Actions
### Critical
- [ ] ...
### High  
- [ ] ...
```

**For coordinate mismatches (abbreviated)**:

```markdown
# Investigation: {repo} build — coordinate mismatch
Date: {date}
Status: Resolved — no deep investigation needed

## Finding: Coordinate Mismatch
**What happened**: Agent assumed {X}. Repo specifies {Y}.
**Evidence**:
| Source | Observation | Confidence |
|--------|-------------|------------|
| Agent | Intended to use {X} | ANECDOTAL |
| CLAUDE.md / AGENTS.md | Specifies {Y} | CONFIG |
| Ground truth | `{command}` confirms {Y} | DEFINITIVE |

**Remediation**: Updated command/config to match spec. Build restarted.
```

---

## Known Patches in This Repo

Keep this table updated. The next agent finds patches here instead of re-deriving them.

These are committed as real `.patch` files — do not re-derive them by hand. Apply
with `make patch-pytorch` / `make patch-vllm-deps`; recapture with `make gen-patches`.
If a patch no longer applies, upstream has drifted past the ref recorded below:
regenerate and update both the file and this table.

| File | Patch file | Patch | Reason | Upstream ref verified | CUDA |
|------|-----------|-------|--------|----------------------|------|
| `src/pytorch/aten/src/ATen/native/sparse/cuda/SparseCsrTensorMath.cu` | `patches/pytorch/local.patch` | Replace `CUDA_R_64F`/`CUDA_R_32F` with `cudssDataType_t` values; add `CUDSS_R_32I` as `indexType` arg | cuDSS 0.8.0 split `cudssMatrixCreateCsr` into 3 type params (offsetType, indexType, valueType) | pytorch `d9abf9e1053` | 13.3 |
| `src/vllm/.deps/vllm-flash-attn-src/CMakeLists.txt:22` | `patches/vllm-deps/vllm-flash-attn.patch` | Added `"3.14"` to `PYTHON_SUPPORTED_VERSIONS` list | Python 3.14 not in upstream allow-list (gated 3.9–3.13) | vllm-flash-attn `b3964b1` (via vllm `09841ae70`) | 13.3 |

---

## Environment Reference

| Variable | Correct value for this machine | Set in |
|----------|-------------------------------|--------|
| `TORCH_CUDA_ARCH_LIST` | `12.0+PTX` (Blackwell RTX PRO 4500) | `cuda-env.sh` |
| `CUDA_HOME` | `/usr/local/cuda-13.3` | `cuda-env.sh` |
| `ASDF_DATA_DIR` | `~/.asdf` | `cuda-env.sh` |
| `MAX_JOBS` | `$(nproc)` = 20 | `build-upstream.sh` |
| `NVCC_THREADS` | `2` | `build-upstream.sh` |
| `CC` / `CXX` | `/usr/bin/gcc-15` / `/usr/bin/g++-15` | `cuda-env.sh` |

---

## Anti-Patterns

- **Never issue a build command before reading CLAUDE.md and AGENTS.md.** The file specifies the exact command. Training memory is ANECDOTAL.
- **Never treat `$!` after a pipeline as the worker PID.** Verify with `ps -p $! -o comm=`.
- **Never declare a build succeeded on exit code 0 alone.** Gate success on `python -c "import $PKG"`.
- **Never explain "0 child jobs" as expected.** Check what PID the monitor is watching first.
- **Never set VLLM_USE_PRECOMPILED=1 for a custom torch build.** Verify the prebuilt index contains an entry for your exact torch version.
- **Never set `USE_<LIB>=0` to work around an API error.** Patch the source. cmake cache ignores env overrides on incremental builds.
- **Never use `local` outside a function body in bash.** Run `bash -n` after every script edit.
- **Never leave TORCH_CUDA_ARCH_LIST unset on a single-GPU machine.** An unset list compiles for all supported arches — a 5–9× time multiplier with zero runtime benefit.
