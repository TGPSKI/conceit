# Contributing to conceit

## Setup

```bash
git clone https://github.com/TGPSKI/conceit.git
cd conceit
source scripts/cuda-env.sh
make check-env
```

`check-env` is the gate. If it fails, fix the prerequisite before writing code —
everything downstream assumes a working CUDA, Python, and `uv`.

You'll also want shellcheck (`pacman -S shellcheck`, `apt install shellcheck`,
`brew install shellcheck`). `make check` refuses to run without it rather than
silently skipping the lint.

## The one workflow that matters

Patches are **generated, not written.** Fix the upstream source in place, then
export the diff:

```bash
$EDITOR src/pytorch/aten/src/ATen/native/sparse/cuda/SparseCsrTensorMath.cu
make gen-patches
git add patches/ && git commit
```

`gen-patches` diffs each source tree against its own upstream HEAD and reports
the ref it captured. Never hand-edit a file under `patches/` — the moment it
disagrees with the tree that produced it, every downstream apply is a coin
flip. If you find yourself editing a `.patch`, you meant to edit `src/`.

When upstream lands the fix, delete the patch file and the row that documents
it.

## Changing scripts

```bash
make check      # shellcheck + bash -n over every script — this is what CI runs
```

Intentional shellcheck exceptions get an inline `# shellcheck disable=SCxxxx`
with the reason on the same line. Don't raise the severity floor in
`.shellcheckrc` to make a warning go away; that hides the next one too.

If you touched build logic, run a real build. CI cannot — there's no GPU on a
GitHub runner — so the only evidence that `build-upstream.sh` still works is a
log from a machine that has one.

## Constraints

- **Never hardcode a GPU architecture.** `TORCH_CUDA_ARCH_LIST` comes from the
  environment. A patch that pins `sm_80` breaks everyone whose card isn't.
- **Never hardcode an absolute path.** Everything derives from the repo root,
  computed from the script's own location. `$HOME/conceit` works only for you.
- **Keep `MAX_JOBS` derived from `nproc`.** A fixed value either wastes a big
  machine or OOMs a small one.
- **Every new env var takes the form `${VAR:-default}`.** Any single value must
  be overridable without editing a file.

## Pull requests

- `make check` passes.
- Build logic changes carry a build log — last 50 lines in the description,
  full log linked.
- A `## [Unreleased]` entry in `CHANGELOG.md`.
- Patch changes update the table in
  [`.agents/skills/build-triage/SKILL.md`](.agents/skills/build-triage/SKILL.md)
  and the one in the README, including the upstream ref.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
