---
name: env-intake
description: "Walk a user through conceit's environment intake on a new machine: discover every CUDA toolkit and host compiler present, resolve which pair nvcc will actually accept, prove it with a compile, and persist the answers to conceit.env. Use before the first build on any machine, when check-env fails on CUDA_HOME/CC/CXX, or when a toolchain moved and the build stopped finding it."
metadata:
  author: conceit
  version: "1.0"
compatibility: "bash, nvcc, gcc/g++, nvidia-smi, uv, make"
---

# conceit Environment Intake

Establish a working build environment on this machine and write it down, so the
next shell and the next agent inherit it instead of rediscovering it.

`scripts/setup.sh` does the mechanical work: scanning, smoke testing, writing
`conceit.env`. This workflow covers what the script cannot decide alone — which
toolkit a machine should standardize on, where an unpackaged toolchain lives,
whether a failed smoke test means "pick another compiler" or "this machine needs
a package."

## Design Principles

- **Discover, never assume.** A hardcoded path passes a prerequisite check on a
  machine that cannot compile. Every value here comes from the filesystem or
  from the user, never from what worked on another host.
- **The compile is the evidence.** Version tables go stale one CUDA release
  later. `nvcc -ccbin <cxx>` on a three-line kernel is DEFINITIVE; a version
  comparison is CONFIG. When they disagree, the compile wins.
- **Persist the answer.** An answer that lives only in this session is one the
  next machine, shell, or agent pays for again.
- **Ask only what the disk cannot say.** Run the scan before the questions.

## Prerequisites

- A CUDA toolkit installed somewhere on this machine (`scripts/install-cuda-toolkit.sh`
  installs one from an NVIDIA runfile, with a gcc shim on PATH).
- A gcc/g++ pair no newer than that toolkit accepts.
- Repo cloned; `make help` runs.

---

## Step 1: Establish the starting state

**Inspect**:

```bash
ls -l conceit.env 2>/dev/null && make setup-show
```

| Status | Action |
|--------|--------|
| `conceit.env` missing | Continue to Step 2 |
| `conceit.env` exists, `make check-env` passes | Report the resolved values, stop. Nothing to do |
| `conceit.env` exists, `check-env` fails | Note which value is wrong, continue to Step 2 — the scan will re-resolve it |
| `conceit.env` exists, toolchain since moved | Continue to Step 2, regenerate |

**Decide**: nothing yet. Do not ask the user anything before the scan runs.

---

## Step 2: Scan the machine

**Inspect**:

```bash
bash scripts/setup.sh --auto      # non-interactive: best candidate for each, still smoke tested
```

Read what it reports before interpreting anything: toolkits found, the gcc cap
parsed from that toolkit's own `crt/host_config.h`, compilers found with
versions, and the smoke-test result.

| Status | Action |
|--------|--------|
| One toolkit, one supported compiler, smoke test clean | Accept it. Skip to Step 5 |
| Multiple toolkits found | Step 3 — the user picks |
| Compilers found but all over the cap | Step 4 — this machine needs a package or a from-source toolchain |
| No compiler found at all | Step 4 |
| Smoke test failed on the auto-picked pair | Step 4 — do not paper over it by raising the cap |

**Never** reach for `nvcc -allow-unsupported-compiler` to make a failing smoke
test pass. It converts a clear five-second failure into a compile error hours
into a build, or into a binary that miscompiles at run time.

---

## Step 3: Choose among what was found

**Inspect**: the candidate list from Step 2. Versions and paths are already
resolved — do not re-derive them.

**Decide**:

1. "Which CUDA toolkit should this machine build against?" — default to the
   newest present. A machine with 12.x and 13.x installed is usually mid-upgrade;
   ask rather than assume the newest is the intended one.
2. "Which host compiler?" — default to the newest at or under the cap.

Then run the interactive intake and make those selections:

```bash
make setup
```

---

## Step 4: Resolve a missing or rejected compiler

**Inspect**:

| Status | Action |
|--------|--------|
| Distro packages a supported gcc | Offer the install command; do not run sudo without confirmation |
| A from-source toolchain exists but is off PATH | Re-scan with `CONCEIT_CC_SEARCH_PATH` |
| A from-source toolchain is too old for the rest of the stack | Say so plainly — rebuilding it is its own project, not a step here |

**Decide**:

1. "Where does your toolchain live?" — only if the scan found nothing usable.
   A compiler built from source is precisely the one PATH does not know about.

```bash
CONCEIT_CC_SEARCH_PATH=/prefix/bin:/other/prefix/bin make setup
```

Install commands, when the machine simply lacks one:

| Distro | Command |
|--------|---------|
| Arch / Manjaro | `sudo pacman -S gcc15` |
| Debian / Ubuntu | `sudo apt install gcc-15 g++-15` |
| Fedora | `sudo dnf install gcc-15 gcc-c++-15` |

Re-run Step 2 after any install. The smoke test, not the package manager's exit
code, is what says the machine is ready.

---

## Step 5: Confirm and hand off

**Generate**: `scripts/setup.sh` writes the file. Do not hand-write it.

Every line keeps the `${VAR:-default}` form the rest of the repo uses, so
precedence stays readable: what the user exported by hand beats
`conceit.env`, which beats the detection defaults in `scripts/cuda-env.sh`.

Write to: `conceit.env` (gitignored — it describes one machine)

```bash
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-13.3}"
export CC="${CC:-/usr/bin/gcc-15}"
export CXX="${CXX:-/usr/bin/g++-15}"
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0+PTX}"
export UV="${UV:-/home/you/.local/bin/uv}"
```

## Validate

```bash
source scripts/cuda-env.sh
make check-env          # every value above, re-verified from a clean shell
```

| Status | Action |
|--------|--------|
| `check-env` passes | Hand off to `make build-all`, or to the build-triage skill if a build then fails |
| `check-env` disagrees with `conceit.env` | The file is stale or something exported in this shell overrides it — `env \| grep -E 'CC\|CXX\|CUDA_HOME'` |

## PR Checkpoint

Intake produces no committed files — `conceit.env` is gitignored and describes
one machine. Open a PR only when the intake exposed a gap in the tooling itself:

**Title**: `[env] <what the scan could not resolve>`

**Files to include**:
- `scripts/setup.sh` — a search path or toolkit layout the scan should have found
- `scripts/cuda-env.sh` — a default that was wrong for this machine
- `Makefile` — a `check-env` gate that passed on an environment that could not build
