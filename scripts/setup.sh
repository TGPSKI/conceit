#!/usr/bin/env bash
#
# Environment intake. Finds every CUDA toolkit and host compiler on this
# machine, proves the pair you pick actually compiles a CUDA translation unit,
# and writes the answers to conceit.env so every future shell inherits them.
#
#   scripts/setup.sh          # interactive
#   scripts/setup.sh --auto   # no prompts: best candidate for each, still smoke tested
#   scripts/setup.sh --show   # print the current conceit.env and exit
#
# The point is that a machine is discovered, not assumed. Hardcoded defaults
# ("gcc-15 lives in /usr/bin") pass a prerequisite check on a machine that
# cannot compile, and you find out an hour into a build.
#
# Compilers built from source rarely sit on PATH. Point at them with:
#   CONCEIT_CC_SEARCH_PATH=/opt/toolchains/bin:/srv/gcc-15/bin scripts/setup.sh

set -euo pipefail
shopt -s nullglob

CONCEIT_ROOT="${CONCEIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${CONCEIT_ENV_FILE:-$CONCEIT_ROOT/conceit.env}"

interactive=1

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*" >&2; }
hdr()  { printf '\n── %s %s\n' "$1" "$(printf '─%.0s' $(seq 1 $((60 - ${#1}))))" >&2; }

case "${1:-}" in
  --auto) interactive=0 ;;
  --show)
    [[ -f "$ENV_FILE" ]] || die "no $ENV_FILE yet — run: make setup"
    cat "$ENV_FILE"
    exit 0
    ;;
  --help|-h)
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) die "unknown argument: $1 (use --auto, --show, or --help)" ;;
esac

# A pipe or a cron job has no one to answer the prompts. Fall back rather than
# block forever on a read that will never return.
if [[ ! -t 0 ]] && (( interactive )); then
  warn "stdin is not a terminal — running as --auto"
  interactive=0
fi

# prompt_choice <default-1-based-index> <item>...
# Renders a menu on stderr and echoes the chosen 1-based index on stdout.
# In --auto mode it echoes the default without rendering anything.
prompt_choice() {
  local default=$1; shift
  local -a items=("$@")
  local i marker reply

  if (( ! interactive )); then
    printf '%s' "$default"
    return 0
  fi

  for i in "${!items[@]}"; do
    marker=""
    (( i + 1 == default )) && marker="  <- default"
    printf '  %2d) %s%s\n' "$((i + 1))" "${items[i]}" "$marker" >&2
  done

  while true; do
    printf 'choice [%s]: ' "$default" >&2
    read -r reply || reply=""
    [[ -z "$reply" ]] && reply=$default
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#items[@]} )); then
      printf '%s' "$reply"
      return 0
    fi
    say "  not one of 1..${#items[@]}"
  done
}

# prompt_value <prompt> <default>
prompt_value() {
  local prompt=$1 default=$2 reply
  if (( ! interactive )); then
    printf '%s' "$default"
    return 0
  fi
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r reply || reply=""
  printf '%s' "${reply:-$default}"
}

# ── CUDA toolkits ─────────────────────────────────────────────────────────────

hdr "CUDA toolkit"

declare -A _seen_cuda=()
declare -a cuda_dirs=()
add_cuda() {
  local d=$1 real
  [[ -n "$d" && -x "$d/bin/nvcc" ]] || return 0
  real=$(cd "$d" && pwd -P)
  [[ -n "${_seen_cuda[$real]:-}" ]] && return 0
  _seen_cuda[$real]=1
  cuda_dirs+=("$real")
}

for _d in "${CUDA_HOME:-}" /usr/local/cuda /usr/local/cuda-* /opt/cuda /opt/cuda-*; do
  add_cuda "$_d"
done
# An nvcc on PATH can live outside every conventional prefix.
if command -v nvcc >/dev/null 2>&1; then
  add_cuda "$(cd "$(dirname "$(command -v nvcc)")/.." && pwd -P)"
fi
unset _d

(( ${#cuda_dirs[@]} )) || die "no CUDA toolkit found (looked for bin/nvcc under /usr/local/cuda*, /opt/cuda*, \$CUDA_HOME, and PATH).
       Install one with: scripts/install-cuda-toolkit.sh /path/to/cuda_*.run"

cuda_version() {
  "$1/bin/nvcc" --version 2>/dev/null | awk '/release/ {gsub(",", "", $(NF-1)); print $(NF-1); exit}'
}

declare -a cuda_labels=()
for _d in "${cuda_dirs[@]}"; do
  cuda_labels+=("$(printf 'CUDA %-6s %s' "$(cuda_version "$_d")" "$_d")")
done
unset _d

# Default to the newest toolkit present.
cuda_default=1
if (( ${#cuda_dirs[@]} > 1 )); then
  _best=$(for i in "${!cuda_dirs[@]}"; do
            printf '%s %s\n' "$(cuda_version "${cuda_dirs[i]}")" "$((i + 1))"
          done | sort -V | tail -1 | awk '{print $2}')
  cuda_default=$_best
  unset _best
fi

say "found ${#cuda_dirs[@]} toolkit(s):"
_pick=$(prompt_choice "$cuda_default" "${cuda_labels[@]}")
CUDA_HOME=${cuda_dirs[$((_pick - 1))]}
cuda_ver=$(cuda_version "$CUDA_HOME")
say "using CUDA $cuda_ver at $CUDA_HOME"

# nvcc's own host_config.h is the authority on which gcc it will accept — not
# a table in a README that goes stale one CUDA release later.
gcc_cap=$(grep -oE '__GNUC__ > [0-9]+' "$CUDA_HOME/include/crt/host_config.h" 2>/dev/null \
          | head -1 | grep -oE '[0-9]+$' || true)
if [[ -n "$gcc_cap" ]]; then
  say "this toolkit accepts host gcc up to $gcc_cap"
else
  warn "could not read a gcc cap from $CUDA_HOME/include/crt/host_config.h — the smoke test still decides"
fi

# ── Host compilers ────────────────────────────────────────────────────────────

hdr "host compiler"

# PATH first, then the places a distro package or a from-source install puts a
# toolchain. A compiler you built yourself is exactly the one PATH does not know
# about, so CONCEIT_CC_SEARCH_PATH is part of the contract, not an escape hatch.
declare -a search_dirs=()
IFS=: read -ra search_dirs <<< "${CONCEIT_CC_SEARCH_PATH:+$CONCEIT_CC_SEARCH_PATH:}$PATH"
search_dirs+=(
  /usr/bin /usr/local/bin /opt/bin
  /opt/*/bin /opt/*/*/bin
  /usr/local/*/bin
  "$HOME/.local/bin" "$HOME/opt/"*/bin "$HOME/toolchains/"*/bin
  "${ASDF_DATA_DIR:-$HOME/.asdf}/installs/gcc/"*/bin
)

declare -A _seen_cc=()
declare -a cc_rows=()   # "version|gcc|g++"
for _dir in "${search_dirs[@]}"; do
  [[ -d "$_dir" ]] || continue
  for _cc in "$_dir"/gcc "$_dir"/gcc-[0-9]*; do
    [[ -x "$_cc" && -f "$_cc" ]] || continue

    # A gcc with no g++ beside it cannot build torch, so pair them up front.
    _cxx="${_cc%/*}/$(basename "$_cc" | sed 's/^gcc/g++/')"
    [[ -x "$_cxx" ]] || _cxx="${_cc%/*}/g++"
    [[ -x "$_cxx" ]] || continue

    _key="$(readlink -f "$_cc"):$(readlink -f "$_cxx")"
    [[ -n "${_seen_cc[$_key]:-}" ]] && continue
    _seen_cc[$_key]=1

    _ver=$("$_cc" -dumpfullversion 2>/dev/null || "$_cc" -dumpversion 2>/dev/null || true)
    [[ -n "$_ver" ]] || continue
    cc_rows+=("$_ver|$_cc|$_cxx")
  done
done
unset _dir _cc _cxx _key _ver

(( ${#cc_rows[@]} )) || die "no gcc/g++ pair found.
       Install one (pacman -S gcc15 | apt install gcc-15 g++-15), or point at a
       from-source toolchain: CONCEIT_CC_SEARCH_PATH=/prefix/bin scripts/setup.sh"

# Newest first, and anything over the cap sinks to the bottom: it is present,
# it is selectable, and it is labelled as the thing nvcc will reject.
declare -a cc_sorted=()
mapfile -t cc_sorted < <(
  for row in "${cc_rows[@]}"; do
    ver=${row%%|*}
    major=${ver%%.*}
    rank=0
    if [[ -n "$gcc_cap" ]] && (( major > gcc_cap )); then rank=1; fi
    printf '%s\t%s\n' "$rank" "$row"
  done | sort -t$'\t' -k1,1n -k2,2Vr | cut -f2
)

declare -a cc_labels=()
for row in "${cc_sorted[@]}"; do
  IFS='|' read -r _ver _cc _cxx <<< "$row"
  note=""
  if [[ -n "$gcc_cap" ]] && (( ${_ver%%.*} > gcc_cap )); then
    note="  (too new — CUDA $cuda_ver stops at gcc $gcc_cap)"
  fi
  cc_labels+=("$(printf 'gcc %-10s %s%s' "$_ver" "$_cc" "$note")")
done
cc_labels+=("enter a path manually")
unset row note _ver _cc _cxx

say "found ${#cc_sorted[@]} compiler(s):"

CC=""; CXX=""
while true; do
  _pick=$(prompt_choice 1 "${cc_labels[@]}")

  if (( _pick == ${#cc_labels[@]} )); then
    CC=$(prompt_value "  path to gcc" "")
    [[ -x "$CC" ]] || { warn "$CC is not executable"; continue; }
    CXX=$(prompt_value "  path to g++" "${CC%/*}/$(basename "$CC" | sed 's/^gcc/g++/')")
    [[ -x "$CXX" ]] || { warn "$CXX is not executable"; continue; }
  else
    IFS='|' read -r _ver CC CXX <<< "${cc_sorted[$((_pick - 1))]}"
  fi

  # ── The gate: a real compile, not a version comparison ────────────────────
  #
  # Everything above is inference. This is the only step that proves nvcc and
  # this host compiler agree, and it costs about three seconds instead of the
  # hour a build spends before failing on the same mismatch.
  probe_dir=$(mktemp -d)
  cat > "$probe_dir/probe.cu" <<'PROBE'
#include <cstdio>
__global__ void probe_kernel() {}
int main() { probe_kernel<<<1, 1>>>(); std::printf("ok\n"); return 0; }
PROBE

  say ""
  say "smoke test: nvcc -ccbin $CXX"
  if "$CUDA_HOME/bin/nvcc" -ccbin "$CXX" -c "$probe_dir/probe.cu" -o "$probe_dir/probe.o" \
       > "$probe_dir/out" 2>&1; then
    say "  compiled clean"
    rm -rf "$probe_dir"
    break
  fi

  say "  FAILED:"
  sed 's/^/    /' "$probe_dir/out" | head -20 >&2
  rm -rf "$probe_dir"

  (( interactive )) || die "smoke test failed for $CXX and no terminal to pick another"
  say ""
  say "pick a different compiler:"
done

say "using gcc $(basename "$CC") -> $CC"

# ── GPU architecture ──────────────────────────────────────────────────────────

hdr "GPU architecture"

arch_default="${TORCH_CUDA_ARCH_LIST:-}"
if [[ -z "$arch_default" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    # nvidia-smi prints its failures (a driver/library version mismatch, say) on
    # stdout in the same shape as a result. Keep only well-formed compute caps,
    # or an unusable driver silently becomes the arch list.
    mapfile -t _caps < <(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                         | tr -d ' ' | grep -E '^[0-9]+\.[0-9]+$' | sort -u || true)
    if (( ${#_caps[@]} )); then
      arch_default=$(printf '%s+PTX;' "${_caps[@]}")
      arch_default=${arch_default%;}
      say "detected: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd',' -)"
    else
      warn "nvidia-smi returned no usable compute capability — is the driver healthy?"
    fi
    unset _caps
  fi
fi
if [[ -z "$arch_default" ]]; then
  arch_default="12.0+PTX"
  warn "no GPU detected — defaulting to $arch_default (leaving this unset compiles every arch, ~9x the nvcc time)"
fi

TORCH_CUDA_ARCH_LIST=$(prompt_value "TORCH_CUDA_ARCH_LIST" "$arch_default")

# ── Supporting tools ──────────────────────────────────────────────────────────

hdr "supporting tools"

UV="${UV:-$HOME/.local/bin/uv}"
if [[ -x "$UV" ]]; then
  say "uv        $("$UV" --version)"
elif command -v uv >/dev/null 2>&1; then
  UV=$(command -v uv)
  say "uv        $("$UV" --version)  ($UV)"
else
  UV=""
  warn "uv not found — vLLM builds need it: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

if command -v python >/dev/null 2>&1; then
  say "python    $(python --version 2>&1)"
else
  warn "python not found on PATH"
fi

# ── Write it down ─────────────────────────────────────────────────────────────

hdr "conceit.env"

if [[ -f "$ENV_FILE" ]] && (( interactive )); then
  say "$ENV_FILE exists:"
  sed 's/^/  /' "$ENV_FILE" >&2
  _ans=$(prompt_value "overwrite? [y/N]" "N")
  [[ "$_ans" =~ ^[Yy] ]] || { say "left alone"; exit 0; }
fi

# Every line keeps the ${VAR:-default} form the rest of the repo uses, so the
# precedence chain stays honest: something you exported by hand still beats this
# file, and this file beats the guesses in cuda-env.sh.
# The ${VAR:-...} has to reach the file literally — expanding it here would bake
# in this shell's values and destroy the precedence chain the file exists for.
# shellcheck disable=SC2016
{
  printf '# Generated by scripts/setup.sh on %s.\n' "$(hostname)"
  printf '# Machine-specific answers, sourced by scripts/cuda-env.sh. Not committed.\n'
  printf '# Edit freely, or re-run `make setup` to regenerate. Delete to fall back to detection.\n'
  printf '\n'
  printf 'export CUDA_HOME="${CUDA_HOME:-%s}"\n' "$CUDA_HOME"
  printf 'export CC="${CC:-%s}"\n' "$CC"
  printf 'export CXX="${CXX:-%s}"\n' "$CXX"
  printf 'export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-%s}"\n' "$TORCH_CUDA_ARCH_LIST"
  if [[ -n "$UV" ]]; then
    printf 'export UV="${UV:-%s}"\n' "$UV"
  fi
} > "$ENV_FILE"

sed 's/^/  /' "$ENV_FILE" >&2

hdr "next"
say "  source scripts/cuda-env.sh   # picks up conceit.env"
say "  make check-env               # re-verifies everything above"
say "  make build-all"
