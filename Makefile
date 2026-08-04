# conceit — build the GPU inference stack from source.
#
# Recipes use `source`, arrays, and process substitution, so they need bash.
# Without this, make uses /bin/sh — dash on Debian/Ubuntu — and every build
# target fails at the first `source`.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Everything resolves relative to the repo root, so a clone works from any
# path. Override REPO_ROOT to keep the source trees outside the checkout.
REPO_ROOT       ?= $(CURDIR)
SCRIPTS_DIR     := $(REPO_ROOT)/scripts
UV              ?= $(HOME)/.local/bin/uv

PYTORCH_URL     := https://github.com/pytorch/pytorch.git
VLLM_URL        := https://github.com/vllm-project/vllm.git
LLAMA_URL       := https://github.com/ggml-org/llama.cpp.git
TORCHVISION_URL := https://github.com/pytorch/vision.git
TORCHAUDIO_URL  := https://github.com/pytorch/audio.git

PYTORCH_DIR     := $(REPO_ROOT)/src/pytorch
VLLM_DIR        := $(REPO_ROOT)/src/vllm
LLAMA_DIR       := $(REPO_ROOT)/src/llama.cpp
TORCHVISION_DIR := $(REPO_ROOT)/src/torchvision
TORCHAUDIO_DIR  := $(REPO_ROOT)/src/torchaudio

PYTORCH_PY      := $(PYTORCH_DIR)/.venv/bin/python
VLLM_PY         := $(VLLM_DIR)/.venv/bin/python

# vLLM's flash-attn is fetched by cmake FetchContent into .deps/, so its patch
# applies there, not at the vLLM repo root.
VLLM_FLASH_DIR  := $(VLLM_DIR)/.deps/vllm-flash-attn-src

SCRIPTS         := $(wildcard scripts/*.sh)

# ── Canned recipes ────────────────────────────────────────────────────────────

# clone_or_pull,<url>,<dir>
define clone_or_pull
if [ -d "$(2)/.git" ]; then \
  echo "pull  $(notdir $(2))"; git -C "$(2)" pull --ff-only; \
else \
  echo "clone $(notdir $(2))"; git clone "$(1)" "$(2)"; \
fi
endef

# require_bins,<binary>...
define require_bins
for b in $(1); do \
  command -v "$$b" >/dev/null 2>&1 || { \
    echo "ERROR: $$b not found — install it and retry (see README prerequisites)"; \
    exit 1; }; \
done
endef

# The vLLM venv is managed by uv and has no torch of its own. Seed it with the
# wheel we built before compiling anything that links against torch.
define seed_vllm_venv
$(UV) pip install --python $(VLLM_PY) --quiet setuptools wheel && \
$(UV) pip install --python $(VLLM_PY) --quiet --no-build-isolation $(PYTORCH_DIR)/dist/torch-*.whl
endef

# ext_cuda,<module>,<src-dir>,<venv-python>
# Full native build. Slow, and needs the system libraries checked above, but it
# is the only variant that gives you working CUDA ops.
define ext_cuda
source $(SCRIPTS_DIR)/cuda-env.sh && cd $(2) && \
FORCE_CUDA=1 $(UV) pip install --python $(3) --no-build-isolation --no-cache-dir . && \
$(3) -c "import $(1); print('$(1):', $(1).__version__, '(cuda ops)')"
endef

# ext_python,<module>,<src-dir>,<venv-python>
# Python-only install, no compiled ops. Minutes instead of an hour, and enough
# to unblock an import path that only needs the pure-Python surface.
define ext_python
source $(SCRIPTS_DIR)/cuda-env.sh && cd $(2) && \
$(UV) pip install --python $(3) --no-build-isolation -e . && \
$(3) -c "import $(1); print('$(1):', $(1).__version__, '(python-only)')"
endef

# apply_patches,<patch-dir>,<target-dir>
# Three outcomes, not two: applies, already applied, or genuinely fails. The
# obvious version prints a warning and exits 0 on failure, which is the
# premature-success-on-exit-0 trap build-triage exists to catch.
define apply_patches
applied=0; skipped=0; \
for p in $(1)/*.patch; do \
  [ -f "$$p" ] || continue; \
  if patch -p1 -d "$(2)" --forward --dry-run < "$$p" >/dev/null 2>&1; then \
    patch -p1 -d "$(2)" --forward < "$$p" >/dev/null; \
    echo "  applied : $$p"; applied=$$((applied+1)); \
  elif patch -p1 -d "$(2)" -R --dry-run < "$$p" >/dev/null 2>&1; then \
    echo "  skipped : $$p (already applied)"; skipped=$$((skipped+1)); \
  else \
    echo "  ERROR   : $$p does not apply to $(2)"; \
    echo "            upstream drifted — regenerate with 'make gen-patches'"; \
    exit 1; \
  fi; \
done; \
echo "$$applied applied, $$skipped already present -> $(2)"
endef

# ── Environment ───────────────────────────────────────────────────────────────

.PHONY: check-env
check-env: ## Validate prerequisites: CUDA, Python, uv, GPU, disk
	@[ -n "$(CUDA_HOME)" ] || { echo "ERROR: CUDA_HOME not set. Run: source scripts/cuda-env.sh"; exit 1; }
	@[ -d "$(CUDA_HOME)" ] || { echo "ERROR: CUDA_HOME=$(CUDA_HOME) does not exist"; exit 1; }
	@$(call require_bins,nvidia-smi python)
	@[ -x "$(CC)" ]  || { echo "ERROR: CC=$(CC) is not an executable compiler. Install a CUDA-supported gcc (pacman -S gcc15 | apt install gcc-15 g++-15), or export CC/CXX"; exit 1; }
	@[ -x "$(CXX)" ] || { echo "ERROR: CXX=$(CXX) is not an executable compiler. Install a CUDA-supported g++ (pacman -S gcc15 | apt install gcc-15 g++-15), or export CC/CXX"; exit 1; }
	@hdr="$(CUDA_HOME)/include/crt/host_config.h"; \
	  max=$$(grep -oE '__GNUC__ > [0-9]+' "$$hdr" 2>/dev/null | head -1 | grep -oE '[0-9]+$$' || true); \
	  have=$$("$(CXX)" -dumpversion 2>/dev/null | cut -d. -f1 || true); \
	  if [ -n "$$max" ] && [ -n "$$have" ] && [ "$$have" -gt "$$max" ]; then \
	    echo "ERROR: $(CXX) is gcc $$have, and this CUDA supports up to gcc $$max — nvcc will refuse to compile."; \
	    echo "       Install gcc $$max and re-source scripts/cuda-env.sh, or export CC/CXX to one."; \
	    exit 1; \
	  fi
	@[ -x "$(UV)" ] || { echo "ERROR: uv not found at $(UV). Install: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
	@[ -n "$(TORCH_CUDA_ARCH_LIST)" ] || echo "WARN: TORCH_CUDA_ARCH_LIST unset — will compile every arch (~9x slower)"
	@echo "python               $$(python --version 2>&1)"
	@echo "gpu                  $$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader)"
	@echo "uv                   $$($(UV) --version)"
	@echo "cuda_home            $(CUDA_HOME)"
	@echo "arch_list            $(TORCH_CUDA_ARCH_LIST)"
	@echo "cc / cxx             $(CC) / $(CXX)"
	@df -h "$(REPO_ROOT)" | awk 'NR==2 {print "disk                 " $$4 " free of " $$2}'

.PHONY: env-show
env-show: ## Print the resolved build paths
	@echo "REPO_ROOT            $(REPO_ROOT)"
	@echo "PYTORCH_DIR          $(PYTORCH_DIR)"
	@echo "VLLM_DIR             $(VLLM_DIR)"
	@echo "LLAMA_DIR            $(LLAMA_DIR)"
	@echo "TORCHVISION_DIR      $(TORCHVISION_DIR)"
	@echo "TORCHAUDIO_DIR       $(TORCHAUDIO_DIR)"
	@echo "UV                   $(UV)"

# ── Build: core ───────────────────────────────────────────────────────────────

.PHONY: build-pytorch
build-pytorch: ## Build PyTorch from source (~2-4h first run)
	@source $(SCRIPTS_DIR)/cuda-env.sh && \
	  bash $(SCRIPTS_DIR)/build-upstream.sh $(PYTORCH_URL) $(PYTORCH_DIR)

.PHONY: build-vllm
build-vllm: ## Build vLLM from source (~30-90min; needs the pytorch wheel)
	@source $(SCRIPTS_DIR)/cuda-env.sh && \
	  bash $(SCRIPTS_DIR)/build-upstream.sh $(VLLM_URL) $(VLLM_DIR)

.PHONY: build-llama
build-llama: ## Build llama.cpp with CUDA
	@source $(SCRIPTS_DIR)/cuda-env.sh && \
	  bash $(SCRIPTS_DIR)/build-upstream.sh $(LLAMA_URL) $(LLAMA_DIR)

.PHONY: build-all
build-all: build-pytorch build-vllm build-llama ## Build pytorch -> vllm -> llama.cpp in order

# ── Build: torchvision / torchaudio ───────────────────────────────────────────
#
# Both must be built against your torch wheel. The PyPI builds are compiled
# against a different CUDA/torch ABI and will fail at import.
#
# Order: build-pytorch, build-torchvision, build-vllm, build-torchvision-vllm.

.PHONY: _clone-torchvision _clone-torchaudio
_clone-torchvision:
	@$(call clone_or_pull,$(TORCHVISION_URL),$(TORCHVISION_DIR))
_clone-torchaudio:
	@$(call clone_or_pull,$(TORCHAUDIO_URL),$(TORCHAUDIO_DIR))

.PHONY: build-torchvision
build-torchvision: _clone-torchvision ## torchvision + CUDA ops into the pytorch venv
	@$(call require_bins,ffmpeg)
	@pkg-config --exists libjpeg libpng || { echo "ERROR: missing libjpeg/libpng dev headers"; exit 1; }
	@$(call ext_cuda,torchvision,$(TORCHVISION_DIR),$(PYTORCH_PY))

.PHONY: build-torchvision-vllm
build-torchvision-vllm: _clone-torchvision ## torchvision + CUDA ops into the vllm venv
	@$(call require_bins,ffmpeg)
	@pkg-config --exists libjpeg libpng || { echo "ERROR: missing libjpeg/libpng dev headers"; exit 1; }
	@$(call seed_vllm_venv)
	@$(call ext_cuda,torchvision,$(TORCHVISION_DIR),$(VLLM_PY))

.PHONY: build-torchvision-python
build-torchvision-python: _clone-torchvision ## torchvision python-only into the pytorch venv (fast)
	@$(call ext_python,torchvision,$(TORCHVISION_DIR),$(PYTORCH_PY))

.PHONY: build-torchvision-python-vllm
build-torchvision-python-vllm: _clone-torchvision ## torchvision python-only into the vllm venv (fast)
	@$(call seed_vllm_venv)
	@$(call ext_python,torchvision,$(TORCHVISION_DIR),$(VLLM_PY))

.PHONY: build-torchaudio
build-torchaudio: _clone-torchaudio ## torchaudio + native backends into the pytorch venv
	@$(call require_bins,sox ffmpeg)
	@$(call ext_cuda,torchaudio,$(TORCHAUDIO_DIR),$(PYTORCH_PY))

.PHONY: build-torchaudio-vllm
build-torchaudio-vllm: _clone-torchaudio ## torchaudio + native backends into the vllm venv
	@$(call require_bins,sox ffmpeg)
	@$(call seed_vllm_venv)
	@$(call ext_cuda,torchaudio,$(TORCHAUDIO_DIR),$(VLLM_PY))

.PHONY: build-torchaudio-python
build-torchaudio-python: _clone-torchaudio ## torchaudio python-only into the pytorch venv (fast)
	@$(call ext_python,torchaudio,$(TORCHAUDIO_DIR),$(PYTORCH_PY))

.PHONY: build-torchaudio-python-vllm
build-torchaudio-python-vllm: _clone-torchaudio ## torchaudio python-only into the vllm venv (fast)
	@$(call seed_vllm_venv)
	@$(call ext_python,torchaudio,$(TORCHAUDIO_DIR),$(VLLM_PY))

.PHONY: build-vision-audio build-vision-audio-vllm
build-vision-audio: build-torchvision build-torchaudio ## Both, with CUDA ops, into the pytorch venv
build-vision-audio-vllm: build-torchvision-vllm build-torchaudio-vllm ## Both, with CUDA ops, into the vllm venv

.PHONY: build-vision-audio-python build-vision-audio-python-vllm
build-vision-audio-python: build-torchvision-python build-torchaudio-python ## Both, python-only, into the pytorch venv
build-vision-audio-python-vllm: build-torchvision-python-vllm build-torchaudio-python-vllm ## Both, python-only, into the vllm venv

# ── Patches ───────────────────────────────────────────────────────────────────
#
# patches/ is generated output. Never hand-edit it: fix the source under src/,
# run gen-patches, and commit what comes out.

.PHONY: gen-patches
gen-patches: ## Export live src/ diffs into patches/
	@bash $(SCRIPTS_DIR)/gen-patches.sh all

.PHONY: patch-pytorch
patch-pytorch: ## Apply patches/pytorch/ to src/pytorch
	@[ -d "$(PYTORCH_DIR)" ] || { echo "ERROR: $(PYTORCH_DIR) not found — run 'make build-pytorch' once to clone it"; exit 1; }
	@$(call apply_patches,patches/pytorch,$(PYTORCH_DIR))

.PHONY: patch-vllm-deps
patch-vllm-deps: ## Apply patches/vllm-deps/ to src/vllm/.deps/vllm-flash-attn-src
	@[ -d "$(VLLM_FLASH_DIR)" ] || { echo "ERROR: $(VLLM_FLASH_DIR) not found — start 'make build-vllm', let cmake fetch the deps, then Ctrl-C and re-run"; exit 1; }
	@$(call apply_patches,patches/vllm-deps,$(VLLM_FLASH_DIR))

.PHONY: patch-all
patch-all: patch-pytorch patch-vllm-deps ## Apply every patch

# ── Test ──────────────────────────────────────────────────────────────────────

.PHONY: test-pytorch
test-pytorch: ## Smoke test the pytorch venv
	@$(PYTORCH_PY) -c "import torch; \
	print('torch:', torch.__version__); \
	print('cuda:', torch.cuda.is_available()); \
	print('device:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none')"

.PHONY: test-vllm
test-vllm: ## Smoke test the vllm venv
	@$(VLLM_PY) -c "import vllm, torch; \
	print('vllm:', vllm.__version__); \
	print('torch:', torch.__version__); \
	print('cuda:', torch.cuda.is_available())"

.PHONY: test
test: test-pytorch test-vllm ## Run every smoke test

.PHONY: status
status: ## Show .build-status.json for each target
	@for d in $(PYTORCH_DIR) $(VLLM_DIR) $(LLAMA_DIR); do \
	  f="$$d/.build-status.json"; \
	  if [ -f "$$f" ]; then printf '%-12s %s\n' "$$(basename $$d)" "$$(cat $$f)"; \
	  else printf '%-12s (not built)\n' "$$(basename $$d)"; fi; \
	done

# ── Quality ───────────────────────────────────────────────────────────────────

.PHONY: lint
lint: ## shellcheck every script
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "ERROR: shellcheck not found. Install: pacman -S shellcheck | apt install shellcheck | brew install shellcheck"; \
	  exit 1; }
	@shellcheck $(SCRIPTS)
	@echo "shellcheck: OK ($(words $(SCRIPTS)) scripts)"

.PHONY: fmt-check
fmt-check: ## bash -n syntax check every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "bash -n: OK ($(words $(SCRIPTS)) scripts)"

.PHONY: check
check: lint fmt-check ## Run every quality gate

# ── Clean ─────────────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove build venvs and wheels (keeps cloned source)
	@rm -rf $(PYTORCH_DIR)/.venv $(PYTORCH_DIR)/dist $(VLLM_DIR)/.venv
	@echo "removed pytorch and vllm venvs"

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-32s\033[0m %s\n", $$1, $$2}'
