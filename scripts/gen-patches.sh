#!/usr/bin/env bash
#
# Export the live diffs in src/ into patches/, so patches/ always reflects what
# is actually in the source tree rather than a hand-maintained copy of it.
#
#   scripts/gen-patches.sh            # all targets
#   scripts/gen-patches.sh pytorch    # one target
#   scripts/gen-patches.sh vllm-deps

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTORCH_DIR="${PYTORCH_DIR:-$REPO_ROOT/src/pytorch}"
VLLM_DIR="${VLLM_DIR:-$REPO_ROOT/src/vllm}"
VLLM_FLASH_DIR="${VLLM_FLASH_DIR:-$VLLM_DIR/.deps/vllm-flash-attn-src}"

# emit_patch <label> <source-dir> <output-file> <hint-when-missing>
#
# The diff is taken against the source tree's own upstream HEAD, which is the
# only baseline that makes a replayable patch. A tree without .git has no such
# baseline, so we say so instead of guessing — a patch generated against an
# empty baseline would list every file as a new file and fail to apply.
emit_patch() {
  local label=$1 src=$2 out=$3 hint=$4

  if [[ ! -d "$src" ]]; then
    printf 'skip  %s: %s not found\n' "$label" "$src"
    [[ -n "$hint" ]] && printf '      %s\n' "$hint"
    return 0
  fi
  if [[ ! -d "$src/.git" ]]; then
    printf 'skip  %s: %s has no .git, so there is no upstream baseline to diff against\n' \
      "$label" "$src"
    return 0
  fi

  mkdir -p "$(dirname "$out")"
  git -C "$src" diff HEAD -- . > "$out"

  if [[ -s "$out" ]]; then
    printf 'write %s: %s (%s lines, upstream %s)\n' \
      "$label" "${out#"$REPO_ROOT"/}" "$(wc -l < "$out")" \
      "$(git -C "$src" rev-parse --short HEAD)"
  else
    rm -f "$out"
    printf 'clean %s: no local changes to export\n' "$label"
  fi
}

gen_pytorch() {
  emit_patch pytorch "$PYTORCH_DIR" "$REPO_ROOT/patches/pytorch/local.patch" \
    "run 'make build-pytorch' once to clone it"
}

gen_vllm_deps() {
  emit_patch vllm-flash-attn "$VLLM_FLASH_DIR" \
    "$REPO_ROOT/patches/vllm-deps/vllm-flash-attn.patch" \
    "start 'make build-vllm', let cmake FetchContent clone the deps, then Ctrl-C and re-run"
}

case "${1:-all}" in
  pytorch)   gen_pytorch ;;
  vllm-deps) gen_vllm_deps ;;
  all)       gen_pytorch; gen_vllm_deps ;;
  *)         printf 'unknown target: %s (use: pytorch | vllm-deps | all)\n' "$1" >&2; exit 2 ;;
esac
