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

<div align="center">

[![Latest Release](https://img.shields.io/github/v/release/hossbit/local-ai-server?style=flat-square&logo=github&logoColor=white&label=Release&color=6C5CE7)](https://github.com/hossbit/local-ai-server/releases/latest)
[![Total Downloads](https://img.shields.io/github/downloads/hossbit/local-ai-server/total?style=flat-square&logo=github&logoColor=white&label=Downloads&color=10B981)](https://github.com/hossbit/local-ai-server/releases)
[![Stars](https://img.shields.io/github/stars/hossbit/local-ai-server?style=flat-square&logo=github&logoColor=white&label=Stars&color=F59E0B)](https://github.com/hossbit/local-ai-server/stargazers)
</div>

## Why Local AI Server?

| Feature                                | **Local AI Server** |         Ollama         |      LM Studio     | OpenAI / Gemini |
| -------------------------------------- | :-----------------: | :--------------------: | :-----------------: | :-------------: |
| Runs fully locally and privately       |          ✅          |            ✅           |          ✅         |        ❌        |
| Designed for Linux servers             |          ✅          |            ✅           | ⚠️ Desktop-focused |        ❌        |
| Uses your existing GGUF files directly |          ✅          |   ⚠️ Import required   |          ✅         |        ❌        |
| Automatic multi-model switching        |          ✅          |            ✅           |          ✅         |  Cloud-managed  |
| OpenAI-compatible API                  |          ✅          |            ✅           |          ✅         |        ✅        |
| User-level systemd service             |          ✅          | ⚠️ Usually system-wide |          ❌         |  Not applicable |
| Transparent `llama.cpp` configuration |          ✅          |      ⚠️ Abstracted     |   ⚠️ GUI-managed   |        ❌        |
| No API fees                            |          ✅          |            ✅           |          ✅         |        ❌        |
| Pure Bash, no extra runtime            |          ✅          |  ⚠️ Ships Go binary   | ⚠️ Electron app    |        ❌        |
| Readable scripts, easy to audit        |          ✅          |  ⚠️ Compiled binary   |  ⚠️ GUI app        |        ❌        |
| Light footprint, fits minimal VPS      |          ✅          |   ⚠️ Moderate         |  ⚠️ Heavy desktop  |        ❌        |

### Main Advantage

> **Local AI Server gives Linux users a private, lightweight and transparent way to run multiple GGUF models through one OpenAI-compatible API, with automatic model switching and systemd service management — all in readable Bash scripts with no runtime to install.**

## What it provides

- OpenAI-compatible chat and completion endpoints
- CPU mode plus optional Vulkan, ROCm, OpenVINO, or SYCL llama.cpp backends
- Automatic discovery of `.gguf` model files, with per-model auto-tuning for GPU hardware
- Multimodal, speculative-decoding, and Prometheus metrics support
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

LocalAI discovers GGUF files from:

```text
~/ai/models
```

Download a `.gguf` model from a source such as Hugging Face, then put it in that
directory. After adding or removing models, reload LocalAI so it regenerates
the config and restarts only if it changed, then list the detected models:

```bash
localai reload
localai models
```

For a single-file model, either place the file directly in `~/ai/models`:

```text
~/ai/models/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
```

or keep it in its own folder:

```text
~/ai/models/Qwen2.5-Coder-7B-Instruct-Q4_K_M/
`-- Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
```

For split GGUF models, keep all shards together in one folder. The first shard
must use canonical llama.cpp split naming, such as `00001-of-00003`:

```text
~/ai/models/DeepSeek-V4-Flash-UD-IQ1_M/
|-- DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf
|-- DeepSeek-V4-Flash-UD-IQ1_M-00002-of-00003.gguf
`-- DeepSeek-V4-Flash-UD-IQ1_M-00003-of-00003.gguf
```

LocalAI registers only the first shard. `llama.cpp` loads the remaining shards
automatically.

Recommended layout:

```text
~/ai/models/
|-- Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
|-- Mistral-7B-Instruct-Q4_K_M/
|   `-- Mistral-7B-Instruct-Q4_K_M.gguf
`-- DeepSeek-V4-Flash-UD-IQ1_M/
    |-- DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf
    |-- DeepSeek-V4-Flash-UD-IQ1_M-00002-of-00003.gguf
    `-- DeepSeek-V4-Flash-UD-IQ1_M-00003-of-00003.gguf
```

If LocalAI warns that files look like non-canonical split fragments, rename the
files to llama.cpp split format or merge them first:

```bash
llama-gguf-split --merge first-fragment.gguf merged-model.gguf
```

Use `localai suggest` after adding large models to get advisory runtime settings
based on your installed models, RAM, backend, and detected GPU memory. It uses
the actual GGUF file size as the base estimate, not an exact parameter-count
formula. Runtime memory also depends on context length, KV cache type, batch
size, backend buffers, and operating-system headroom.

GPU-backed installs auto-tune per-model GPU layers, KV cache type, and
flash-attention from your hardware, and enable free self-speculative decoding
by default. On multi-GPU systems, `LOCALAI_SPLIT_MODE`, `LOCALAI_TENSOR_SPLIT`,
`LOCALAI_MAIN_GPU`, and `LOCALAI_DEVICE` control how models are placed across
devices. See the wiki for per-model overrides (`models.d`), multi-GPU tuning,
multimodal `--mmproj` setup, speculative-decoding tuning, metrics, and startup
preloading.

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
| `localai reload` | Rescan models and restart only if `config.yaml` would change; prints added/removed models. |
| `localai status` | Show service, process, API, and port status. |
| `localai check` | Check the API and model list. |
| `localai models` | List installed `.gguf` models and show loaded state when the API is reachable. |
| `localai suggest` | Suggest runtime settings from installed model sizes and detected hardware. |
| `localai load MODEL` | Warm one model. |
| `localai unload MODEL` | Release one loaded model. |
| `localai key ...` | Manage API keys (`create`, `list`, `revoke`, `rotate`) — see [API keys](#api-keys). |
| `localai update` | Update installed components. |
| `localai version` | Show component versions. |
| `localai uninstall` | Remove helper files; models are kept by default. |

## API keys

By default the API has no authentication, matching llama-swap's own default —
fine as long as `LOCALAI_LISTEN_HOST` stays `127.0.0.1` (loopback only, the
default). If you plan to reach it from another machine on your LAN, create at
least one key first.

```bash
localai key create work-laptop   # name is just a label; shown once, then masked
localai key list                 # id, name, created, status, masked fingerprint
localai key revoke <id>          # deactivate a key immediately
localai key rotate <id>          # issue a replacement, then revoke the old one
```

`create` and `rotate` print the full secret exactly once, right after it's
active — save it immediately, it cannot be shown again:

```
Key created: work-laptop
  id:      a1b2c3d4e5f6
  created: 2026-07-23T16:32:10Z

Save this key now - it will not be shown again:

    sk-localai-9f1a2b3c4d5e6f7089...

Use it as a Bearer token:
  curl http://127.0.0.1:11435/v1/models \
    -H "Authorization: Bearer sk-localai-9f1a2b3c4d5e6f7089..."
```

Once at least one key is active, every request needs it:

```bash
curl http://127.0.0.1:11435/v1/models \
  -H "Authorization: Bearer sk-localai-REPLACE_ME"
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11435/v1",
    api_key="sk-localai-REPLACE_ME",
)
```

Behavior notes:

- **No active keys**: the API stays unauthenticated (today's default, and what
  every existing install keeps doing after an upgrade — nothing changes until
  you run `localai key create`).
- **First active key**: every request now needs a valid `Authorization: Bearer`
  header.
- **Revoking the last key**: the API goes back to unauthenticated, unless you
  set `LOCALAI_REQUIRE_API_KEY=1` in `localai.conf`, which makes config
  generation refuse to produce an unauthenticated config at all.
- **Lost key**: there's no recovery; `rotate` the key (or `revoke` it and
  `create` a new one).
- Keys live in `conf/api-keys.tsv` (mode `0600`, outside Git). Active keys
  are also rendered into `conf/keys.d/keys.yaml` (mode `0600`), each with a
  `# name` comment above it, and merged into the running config via
  llama-swap's `--config-dir` — `config.yaml` itself never contains a
  plaintext key. Manage keys through `localai key ...`, not by hand-editing
  either file; `keys.yaml` is removed entirely once no keys are active.
- Creating, revoking, or rotating a key restarts the running service so the
  change takes effect immediately (same "only restart if something actually
  changed" rule `localai reload` already uses for models).

API keys authenticate requests; they don't encrypt them. For LAN/WAN access,
put a TLS-terminating reverse proxy in front and restrict it with a firewall
— see [Security](#security).

## Documentation

- [ComAI And LocalAI](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/ComAI-and-LocalAI.md)
- [Local AI Service](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-AI-Service.md)
- [Troubleshooting](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Troubleshooting.md)

## Security

The helper scripts bind llama-swap to `127.0.0.1`, so the API is available only
on the local machine by default. Do not expose it to a network without adding
authentication ([`localai key create`](#api-keys)), TLS, and appropriate
firewall rules.

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
