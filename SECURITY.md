# Security Policy

## Supported Versions

| Version | Supported |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

Report privately via
[GitHub Security Advisory](https://github.com/TGPSKI/conceit/security/advisories/new),
which allows coordinated disclosure. Please don't open a public issue for a
vulnerability.

Include the affected file and line numbers, and a reproduction if you have one.

## Trust model

conceit is a **single-user build tool**. It runs on your workstation, with your
privileges, and compiles code it downloads from the internet. The threat model
assumes one trusted operator; there is no sandbox between conceit and the rest
of your machine.

- **`build_cmd` is passed to `eval`, deliberately.** Preset composition needs
  it, and the presets are the point of the tool. The consequence is that
  `BUILD_CMD`, `PREBUILD_CMD`, and `BUILD_DIST_CMD` execute arbitrary shell as
  you. Never set them from anything you didn't write, and never run conceit
  somewhere those can come from a webhook, a CI variable, or a config file
  someone else can edit.

- **The build is the supply chain.** conceit clones from GitHub and installs
  from PyPI over HTTPS, with no verification beyond git transport security and
  whatever `uv` enforces. A compromised upstream repo or package lands compiled
  code in your venv. That's true of every from-source build — conceit just
  automates it. Pin hashes in a requirements file if that trade isn't
  acceptable to you.

- **`sudo` is used exactly once**, in `install-cuda-toolkit.sh`, to run
  NVIDIA's runfile installer. Read the script before running it. It builds a
  temp directory of compiler symlinks and puts it on `PATH` for that one
  command; it does not touch your system compiler.

- **Build logs land in `/tmp` and are world-readable** on most Linux systems
  (`/tmp/build-upstream-*.log`). Upstream build systems occasionally echo
  environment values. The log is removed when the build exits, but it exists
  for the hours in between — set `TMPDIR` somewhere private if that matters.

- **Patches execute nothing, but they do modify source.** `make patch-*`
  applies committed diffs to cloned upstream trees before you compile them.
  Read a patch before trusting it, same as any other diff.

## Out of scope

Vulnerabilities in PyTorch, vLLM, llama.cpp, or the CUDA toolkit — report those
upstream. conceit builds this software; it doesn't maintain it.
