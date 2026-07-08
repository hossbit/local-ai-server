# Local AI Server for Linux

<div align="center">
  <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localai-hero.png" alt="LocalAI local LLM server" width="900">
</div>

<div align="center">

![Linux](https://img.shields.io/badge/Linux-x86--64-111827)
![Debian-based](https://img.shields.io/badge/Debian--based-apt--get-A81D33)
![Red Hat-based](https://img.shields.io/badge/Red%20Hat--based-dnf%20%7C%20yum-EE0000)
![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp-6C5CE7)
![API](https://img.shields.io/badge/API-OpenAI--compatible-111827)
![Service](https://img.shields.io/badge/Service-systemd%20user-F59E0B)
![License](https://img.shields.io/badge/License-MIT-10B981)
</div>

Run GGUF language models locally with
[llama.cpp](https://github.com/ggml-org/llama.cpp),
CPU or GPU acceleration, and
[llama-swap](https://github.com/mostlygeek/llama-swap).
The server exposes an OpenAI-compatible API and discovers models placed in
the configured install directory, which defaults to `~/ai/models`.

## What it provides

- OpenAI-compatible chat and completion endpoints
- CPU mode plus optional Vulkan, ROCm, OpenVINO, or SYCL llama.cpp backends
- Automatic discovery of `.gguf` model files
- On-demand model loading and switching through llama-swap
- A systemd user service
- A `localai` command for service, model, update, and uninstall tasks

## Requirements

- Ubuntu, Debian, Fedora, RHEL, or another compatible x86-64 Linux system
- A working CPU install, or a supported GPU/runtime for your selected backend
- `sudo` access during installation
- Enough RAM and VRAM for the model and quantization you choose

The installer downloads current `llama.cpp` and `llama-swap` releases and can
install required packages with `apt-get`, `dnf`, or `yum`.

## Install

One-line install:

```bash
curl -fsSL https://hossbit.github.io/localai/install.sh | bash
```

CPU-only install:

```bash
curl -fsSL https://hossbit.github.io/localai/install.sh | LLAMA_CPP_BACKEND=cpu bash
```

The default install directory is `~/ai`. See the wiki for custom directories,
manual installs, backend selection, and pinned component versions.

## Add a model

Place one or more `.gguf` files in:

```text
~/ai/models
```

Split GGUF models are supported when shards use llama.cpp naming, such as
`name-00001-of-00003.gguf`. For many split models, use one folder per model.
The exposed model ID is the filename without `.gguf`, or the folder name when a
folder contains one model.

## Use the server

Start LocalAI:

```bash
localai start
localai check
```

The API is available at `http://127.0.0.1:$(cat ~/ai/conf/port)/v1`.

## Service and helper commands

Most users only need these:

| Command | Purpose |
| --- | --- |
| `localai start` | Start the service. |
| `localai stop` | Unload loaded models, then stop the service. |
| `localai restart` | Restart the service. |
| `localai status` | Show service, process, API, and port status. |
| `localai check` | Check the API and model list. |
| `localai models` | List installed `.gguf` models and show loaded state when the API is reachable. |
| `localai suggest` | Suggest runtime settings from installed model sizes and detected hardware. |
| `localai load MODEL` | Warm one model. |
| `localai unload MODEL` | Release one loaded model. |
| `localai update` | Update installed components. |
| `localai version` | Show component versions. |
| `localai uninstall` | Remove helper files; models are kept by default. |

## Documentation

- [ComAI And LocalAI](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/ComAI-and-LocalAI.md)
- [Local AI Service](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-AI-Service.md)
- [Troubleshooting](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Troubleshooting.md)

## Security

The helper scripts bind llama-swap to `127.0.0.1`, so the API is available only
on the local machine by default. Do not expose it to a network without adding
authentication, TLS, and appropriate firewall rules.

## Credits

This project is built on top of:

- https://github.com/ggml-org/llama.cpp
- https://github.com/mostlygeek/llama-swap

Special thanks to the maintainers and contributors of these projects.

LocalAI focuses on simplifying installation, configuration, model management,
and service deployment for local LLM environments.

## Support

<div align="center">
  <a href="https://buymeacoffee.com/mirhh">
    <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/bmc-button.png" alt="Buy me a coffee" width="300">
  </a>
</div>
<div align="center">
  <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/give-it-a-star.png" alt="If this repo helped you, give it a star" width="100%">
</div>
