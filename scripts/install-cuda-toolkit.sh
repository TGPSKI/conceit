#!/usr/bin/env bash
#
# Install the CUDA toolkit from an NVIDIA runfile, with a gcc-15 shim on PATH.
#
# CUDA 13.x needs gcc-15 for C++20, and the runfile picks up whatever `cc` and
# `c++` resolve to. We hand it a temp directory of symlinks rather than
# changing the system default compiler.
#
# usage: install-cuda-toolkit.sh /path/to/cuda_13.3.0_*.run [runfile args...]

set -euo pipefail

GCC="${GCC:-/usr/bin/gcc-15}"
GXX="${GXX:-/usr/bin/g++-15}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if (( $# < 1 )); then
  printf 'usage: %s /path/to/cuda_13.3.0_*.run [runfile args...]\n' "$0" >&2
  printf 'example: %s ./cuda/cuda_13.3.0_610.43.02_linux.run --toolkit\n' "$0" >&2
  exit 2
fi

runfile="$1"
shift

[[ -f "$runfile" ]] || die "runfile not found: $runfile"
[[ -x "$GCC" ]]     || die "$GCC not found — install gcc 15, or set GCC=/path/to/gcc"
[[ -x "$GXX" ]]     || die "$GXX not found — install g++ 15, or set GXX=/path/to/g++"

shimdir="$(mktemp -d)"
trap 'rm -rf "$shimdir"' EXIT

ln -s "$GCC" "$shimdir/gcc"
ln -s "$GCC" "$shimdir/cc"
ln -s "$GXX" "$shimdir/g++"
ln -s "$GXX" "$shimdir/c++"

# Default to a toolkit-only install: the bundled driver is usually older than
# the one already running, and downgrading it breaks a working system.
(( $# == 0 )) && set -- --toolkit

sudo env PATH="$shimdir:$PATH" sh "$runfile" "$@"
