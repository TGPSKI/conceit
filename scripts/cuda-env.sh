#!/usr/bin/env bash
#
# Source this before any CUDA build: sets CUDA_HOME, the arch list, a CUDA-safe
# host compiler, and the NVIDIA library staging paths.
#
#   source scripts/cuda-env.sh
#
# Everything here defers to a value you already exported, so any single knob
# can be overridden without editing this file.

export ASDF_DIR="${ASDF_DIR:-$HOME/.local/share/asdf}"
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
if [[ -s "$ASDF_DIR/asdf.sh" ]]; then
  source "$ASDF_DIR/asdf.sh"
fi

# Repo root comes from this script's own location, so a clone works anywhere.
export CONCEIT_ROOT="${CONCEIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CUDA_STAGE_ROOT="${CUDA_STAGE_ROOT:-$CONCEIT_ROOT/cuda}"

if [[ -z "${CUDA_HOME:-}" ]]; then
  for _d in /usr/local/cuda-13.3 /usr/local/cuda; do
    [[ -d "$_d" ]] && { export CUDA_HOME="$_d"; break; }
  done
  export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-13.3}"
  unset _d
fi

export CUDA_PATH="$CUDA_HOME"
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$CUDA_HOME/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# cuDNN / cuBLASMp / cuDSS ship as versioned archive directories. Glob for them
# under cuda/ instead of pinning exact versions, so extracting a new archive is
# the whole upgrade. Set <NAME>_ROOT explicitly to override.
_stage_dir() {
  local d
  for d in "$CUDA_STAGE_ROOT"/$1; do
    [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
  done
}

export CUDNN_ROOT="${CUDNN_ROOT:-$(_stage_dir 'cudnn-*')}"
export CUBLASMP_ROOT="${CUBLASMP_ROOT:-$(_stage_dir 'libcublasmp-*')}"
export CUDSS_ROOT="${CUDSS_ROOT:-$(_stage_dir 'libcudss-*')}"

for _root in "$CUDNN_ROOT" "$CUBLASMP_ROOT" "$CUDSS_ROOT"; do
  [[ -n "$_root" && -d "$_root" ]] || continue
  export LD_LIBRARY_PATH="$_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export CMAKE_PREFIX_PATH="$_root${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
done
unset _root

# Blackwell sm_120 only. +PTX embeds forward-compatible PTX beside the cubin.
# Leaving this unset compiles every supported arch — roughly 9x the nvcc time.
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0+PTX}"

export CC="${CC:-/usr/bin/gcc-15}"
export CXX="${CXX:-/usr/bin/g++-15}"
export CUDAHOSTCXX="${CUDAHOSTCXX:-$CXX}"
export CMAKE_C_COMPILER="${CMAKE_C_COMPILER:-$CC}"
export CMAKE_CXX_COMPILER="${CMAKE_CXX_COMPILER:-$CXX}"

# Keep site-packages out of the build venvs, copy rather than hardlink across
# filesystems, and opt out of upstream telemetry.
export PYTHONNOUSERSITE=1
export UV_LINK_MODE=copy
export VLLM_NO_USAGE_STATS=1
export DO_NOT_TRACK=1
