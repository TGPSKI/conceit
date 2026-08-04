#!/usr/bin/env bash

set -euo pipefail

# Repo root derived from this script's own location, so a clone works from any
# path. CONCEIT_ROOT (set by cuda-env.sh) still takes precedence.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: build-upstream.sh REPO_URL [DEST_DIR]

Environment overrides:
  PRESET                preset to apply: pytorch, vllm, llama.cpp, or auto
  BRANCH                git branch to clone/pull (default: current default branch)
  ENV_SCRIPT            build env script to source (default: <repo>/scripts/cuda-env.sh)
  VENV_DIR              repo-local venv directory name (default: .venv)
  BUILD_CMD              command to run after venv activation
                        (default: python -m pip install -e .)
  BUILD_DIST_CMD        command to produce wheels
                        (default: python -m build --wheel --outdir dist)
  BOOTSTRAP_PIP_DEPS     space-separated bootstrap deps for the venv
                        (default: pip setuptools wheel build)
  EXTRA_PIP_DEPS         extra packages to install into the venv
                        (default: cmake ninja packaging)

Examples:
  build-upstream.sh https://github.com/pytorch/pytorch.git ~/src/pytorch
  PRESET=vllm build-upstream.sh https://github.com/vllm-project/vllm.git ~/src/vllm
  PRESET=llama.cpp build-upstream.sh https://github.com/ggml-org/llama.cpp.git ~/src/llama.cpp
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ts() { date '+%H:%M:%S'; }
ts_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() { printf '[%s] %s\n' "$(ts)" "$*"; }

# Write/update a machine-readable status file so any watcher can poll it
# without grepping log text.  Fields: phase, ts, step, jobs, detail.
_status_file=""

# `detail` carries build commands and repo URLs, which routinely contain
# quotes and backslashes. Escape them or the status file stops being parseable
# JSON exactly when something interesting is happening.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

emit_status() {
  local phase=$1 step=${2:-null} jobs=${3:-0} detail=${4:-}
  [[ -z "$_status_file" ]] && return
  printf '{"phase":"%s","ts":"%s","step":"%s","jobs":%s,"detail":"%s"}\n' \
    "$(json_escape "$phase")" "$(ts_iso)" "$(json_escape "$step")" \
    "$jobs" "$(json_escape "$detail")" \
    > "${_status_file}.tmp" && mv "${_status_file}.tmp" "$_status_file"
}

# Count all descendants of a PID (not just direct children).
count_descendants() {
  local root=$1 total=0 children
  children=$(pgrep -P "$root" 2>/dev/null || true)
  for c in $children; do
    total=$((total + 1 + $(count_descendants "$c")))
  done
  printf '%s' "$total"
}

retry() {
  local attempts=${1:?attempts required}
  shift
  local n=1
  local delay=10
  while true; do
    if "$@"; then
      return 0
    fi
    if (( n >= attempts )); then
      return 1
    fi
    printf 'retry %d/%d after failure: %s\n' "$n" "$attempts" "$*" >&2
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

# Kill any stale ninja/cmake/pip build processes, report system state, show CLAUDE.md build section.
preflight_check() {
  local target_dir=${1:-$(pwd)}
  printf '\n=== preflight [%s] target=%s ===\n' "$(ts)" "$target_dir"

  local stale_pids
  stale_pids=$(pgrep -f "ninja.*install|cmake.*--build|python.*pip.*install" 2>/dev/null || true)
  if [[ -n "$stale_pids" ]]; then
    log "stale build pids detected: $stale_pids — killing"
    for p in $stale_pids; do
      local pgid
      pgid=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ') || true
      if [[ -n "$pgid" && "$pgid" != "$$" ]]; then
        kill -- "-$pgid" 2>/dev/null || kill "$p" 2>/dev/null || true
      fi
    done
    sleep 3
    local still_alive
    still_alive=$(pgrep -f "ninja.*install|cmake.*--build" 2>/dev/null || true)
    if [[ -n "$still_alive" ]]; then
      log "WARNING: pids still alive after kill: $still_alive"
    else
      log "stale processes cleared"
    fi
  else
    log "no stale build processes"
  fi

  log "memory : $(free -h | awk '/^Mem:/{print $3" / "$2}')"
  log "disk   : $(df -h "$target_dir" | awk 'NR==2{print $3" / "$2" ("$5" used)"}')"
  log "cpus   : $(nproc) logical"

  if [[ -f "$target_dir/CLAUDE.md" ]]; then
    log "CLAUDE.md found — build section:"
    printf '%s\n' '---'
    awk '/^# Build/{p=1; next} p && /^#/{exit} p{print}' "$target_dir/CLAUDE.md" | head -20
    printf '%s\n' '---'
  fi

  printf '=== end preflight ===\n\n'
}

# Background process: every MONITOR_INTERVAL seconds emit timestamp + current
# ninja step + full descendant count, and update the status file.
progress_monitor() {
  local build_pid=$1
  local log_file=$2
  local interval=${MONITOR_INTERVAL:-60}

  while kill -0 "$build_pid" 2>/dev/null; do
    sleep "$interval"
    if ! kill -0 "$build_pid" 2>/dev/null; then
      break
    fi
    local last_step total_jobs
    # Primary: grep the captured build log (works for pytorch/llama.cpp)
    last_step=$(grep -oP '\[\K[0-9]+/[0-9]+(?=\])' "$log_file" 2>/dev/null | tail -1 || true)

    # Fallback: for vllm/uv builds, nvcc processes run in /tmp work dirs.
    # pwdx on any nvcc pid gives us the build dir; grep there for ninja steps.
    if [[ -z "$last_step" ]]; then
      last_step=$(
        for pid in $(pgrep nvcc 2>/dev/null || pgrep ninja 2>/dev/null || true); do
          _wdir=$(pwdx "$pid" 2>/dev/null | awk '{print $2}')
          if [[ -n "$_wdir" && -d "$_wdir" ]]; then
            grep -rhoP '\[\K[0-9]+/[0-9]+(?=\])' "$_wdir" 2>/dev/null || true
          fi
        done | tail -1
      )
    fi

    [[ -z "$last_step" ]] && last_step="?/?"
    total_jobs=$(count_descendants "$build_pid")
    log "progress: step $last_step | $total_jobs active processes (all descendants)" >&2
    emit_status "building" "$last_step" "$total_jobs"
  done
}

repo_url=${1:-}
[[ -n "$repo_url" ]] || { usage >&2; exit 2; }

dest_dir=${2:-}
if [[ -z "$dest_dir" || "$dest_dir" == --* ]]; then
  dest_dir=${dest_dir:-}
  if [[ -z "$dest_dir" ]]; then
    repo_name=$(basename "$repo_url")
    repo_name=${repo_name%.git}
    dest_dir="${CONCEIT_ROOT:-$_repo_root}/src/$repo_name"
  fi
fi

# Scale to the machine. NVCC_THREADS=2 keeps per-nvcc memory in check; raising
# it alongside MAX_JOBS is the fastest way to OOM a big PyTorch build.
MAX_JOBS=${MAX_JOBS:-$(nproc)}
NVCC_THREADS=${NVCC_THREADS:-2}

branch=${BRANCH:-}
venv_dir=${VENV_DIR:-.venv}
env_script=${ENV_SCRIPT:-$_repo_root/scripts/cuda-env.sh}
bootstrap_pip_deps=${BOOTSTRAP_PIP_DEPS:-"pip setuptools wheel build"}
extra_pip_deps=${EXTRA_PIP_DEPS:-"cmake ninja packaging"}
prebuild_cmd=${PREBUILD_CMD:-""}
build_cmd=${BUILD_CMD:-"MAX_JOBS=${MAX_JOBS} NVCC_THREADS=${NVCC_THREADS} python -m pip install -e ."}
build_dist_cmd=${BUILD_DIST_CMD:-"python -m build --wheel --outdir dist"}
preset=${PRESET:-auto}

[[ -f "$env_script" ]] || die "env script not found: $env_script"

# shellcheck disable=SC1090
source "$env_script"

repo_slug=$(basename "${dest_dir%.git}")
if [[ "$preset" == auto ]]; then
  case "$repo_slug" in
    pytorch)      preset=pytorch ;;
    vllm)         preset=vllm ;;
    llama.cpp|llama-cpp|llama_cpp) preset=llama.cpp ;;
  esac
fi

case "$preset" in
  pytorch)
    build_cmd=${BUILD_CMD:-"MAX_JOBS=${MAX_JOBS} NVCC_THREADS=${NVCC_THREADS} python -m pip install -e . -v --no-build-isolation"}
    build_dist_cmd=${BUILD_DIST_CMD:-"python -m pip wheel --no-build-isolation --no-deps -w dist ."}
    extra_pip_deps=${EXTRA_PIP_DEPS:-"cmake ninja packaging pyyaml typing_extensions six"}
    ;;
  vllm)
    # vllm uses uv (per AGENTS.md). We override the torch==2.11.0 pin with our
    # locally built wheel so cuda-toolkit==13.0.2 never enters the dep graph.
    _pt_dist="${CONCEIT_ROOT:-$_repo_root}/src/pytorch/dist"
    # shellcheck disable=SC2012  # ls+sort -V picks the highest torch version; find cannot version-sort
    _pt_wheel=$(ls "$_pt_dist"/torch-*.whl 2>/dev/null | sort -V | tail -1)
    if [[ -z "$_pt_wheel" ]]; then
      log "WARNING: no pytorch wheel found in $_pt_dist — vllm may pull torch from PyPI"
    fi
    _uv="${HOME}/.local/bin/uv"
    [[ -x "$_uv" ]] || die "uv not found at $_uv — install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    # Override file pins our local torch so uv ignores the torch==2.11.0 runtime constraint
    _override_file=$(mktemp /tmp/vllm-torch-override-XXXXXX.txt)
    if [[ -n "$_pt_wheel" ]]; then
      _torch_ver=$(python3 -c "import re; m=re.search(r'torch-([^-]+)', '$_pt_wheel'); print(m.group(1))" 2>/dev/null || echo "")
      [[ -n "$_torch_ver" ]] && printf 'torch==%s\n' "$_torch_ver" > "$_override_file"
    fi
    # Install all build-system requires (except torch, handled via wheel) then torch wheel
    _vllm_build_deps="cmake ninja packaging 'setuptools>=77,<81' 'setuptools-scm>=8' 'setuptools-rust>=1.9' wheel jinja2"
    # These build command strings are consumed by `eval` further down, so the
    # single quotes are intentional: they must survive into the eval to protect
    # wheel/override paths containing spaces.
    # shellcheck disable=SC2016
    prebuild_cmd=${PREBUILD_CMD:-"$_uv pip install $_vllm_build_deps${_pt_wheel:+ '$_pt_wheel'}"}
    # shellcheck disable=SC2016
    build_cmd=${BUILD_CMD:-"$_uv pip install -e . --no-build-isolation${_override_file:+ --override '$_override_file'}"}
    build_dist_cmd=${BUILD_DIST_CMD:-":"}
    extra_pip_deps=${EXTRA_PIP_DEPS:-""}
    bootstrap_pip_deps=${BOOTSTRAP_PIP_DEPS:-""}
    venv_dir=${VENV_DIR:-.venv}
    # uv manages its own venv; we skip the pip-bootstrap step
    ;;
  llama.cpp)
    build_cmd=${BUILD_CMD:-"cmake -S . -B build -DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON && cmake --build build -j"}
    build_dist_cmd=${BUILD_DIST_CMD:-":"}
    ;;
  auto)
    ;;
  *)
    die "unknown PRESET: $preset"
    ;;
esac

mkdir -p "$(dirname "$dest_dir")"
_status_file="$dest_dir/.build-status.json"
emit_status "init" null 0 "$repo_url"

if [[ -d "$dest_dir/.git" ]]; then
  log "repo exists: $dest_dir"
  emit_status "pull" null 0 "$dest_dir"
  git -C "$dest_dir" pull --ff-only
else
  log "cloning $repo_url -> $dest_dir"
  emit_status "clone" null 0 "$repo_url"
  if [[ -n "$branch" ]]; then
    git clone --branch "$branch" "$repo_url" "$dest_dir"
  else
    git clone "$repo_url" "$dest_dir"
  fi
fi

if [[ -f "$dest_dir/.gitmodules" ]]; then
  log "syncing submodules with retries"
  emit_status "submodules" null 0
  retry 5 env GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=600 \
    git -C "$dest_dir" submodule update --init --recursive --jobs 4
fi

cd "$dest_dir"

# Run preflight after clone so CLAUDE.md is available
preflight_check "$dest_dir"

emit_status "venv" null 0 "$venv_dir"
if [[ ! -d "$venv_dir" ]]; then
  log "creating venv: $dest_dir/$venv_dir"
  if [[ -n "${_uv:-}" ]]; then
    "$_uv" venv --python "$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" "$venv_dir"
  else
    python -m venv "$venv_dir"
  fi
fi

# shellcheck disable=SC1090
source "$venv_dir/bin/activate"
# shellcheck disable=SC1090
source "$env_script"

# Both are space-separated package lists that must word-split into separate
# arguments; quoting them would pass one bogus package name.
# shellcheck disable=SC2086
[[ -z "$bootstrap_pip_deps" ]] || python -m pip install --upgrade $bootstrap_pip_deps
# shellcheck disable=SC2086
[[ -z "$extra_pip_deps" ]]    || python -m pip install --upgrade $extra_pip_deps

mkdir -p dist

# Build log for the monitor to tail. Clean up the log and both helper
# processes on any exit, including Ctrl-C — otherwise an interrupted build
# leaves an orphaned tail and monitor behind.
build_log=$(mktemp /tmp/build-upstream-XXXXXX.log)
tail_pid=""
monitor_pid=""
cleanup() {
  [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null
  [[ -n "$tail_pid" ]] && kill "$tail_pid" 2>/dev/null
  rm -f "$build_log"
  return 0
}
trap cleanup EXIT

if [[ -n "$prebuild_cmd" ]]; then
  log "running prebuild: $prebuild_cmd"
  emit_status "prebuild" null 0
  eval "$prebuild_cmd"
fi

log "starting build: $build_cmd"
emit_status "build_start" null 0 "$build_cmd"
# Redirect rather than pipe: `cmd | tee log &` sets $! to tee's PID, which would
# make the monitor watch tee (0 descendants) and make `wait` return tee's exit
# code — a failed build would report success. Background a separate tail for the
# live console output instead, so $build_pid is the real build worker.
eval "$build_cmd" > "$build_log" 2>&1 &
build_pid=$!

tail -f "$build_log" &
tail_pid=$!

progress_monitor "$build_pid" "$build_log" &
monitor_pid=$!

# The EXIT trap reaps the monitor and tail on the failure path.
if wait "$build_pid"; then
  log "build succeeded"
  emit_status "build_done" null 0
else
  build_rc=$?
  emit_status "failed" null 0 "exit $build_rc"
  die "build failed (exit $build_rc) — see log above"
fi

# Stop tailing before the wheel step so its output isn't interleaved.
kill "$monitor_pid" 2>/dev/null || true
kill "$tail_pid" 2>/dev/null || true
monitor_pid=""
tail_pid=""

log "starting wheel command: $build_dist_cmd"
if [[ "$build_dist_cmd" != ":" ]]; then
  emit_status "wheel" null 0
  eval "$build_dist_cmd"
fi
emit_status "done" null 0
log "done"
