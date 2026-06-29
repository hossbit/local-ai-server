# Local AI Server for Linux

<div align="center">
  <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localai-hero.png" alt="LocalAI local LLM server" width="900">
</div>

<div align="center">

![Ubuntu](https://img.shields.io/badge/Linux-Ubuntu-E95420)
![Debian](https://img.shields.io/badge/Linux-Debian-A81D33)
![Fedora](https://img.shields.io/badge/Linux-Fedora-51A2DA)
![RHEL](https://img.shields.io/badge/Linux-RHEL-EE0000)
![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25)
![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp-6C5CE7)
![CPU](https://img.shields.io/badge/Backend-CPU-64748B)
![Vulkan](https://img.shields.io/badge/Backend-Vulkan-AC162C)
![ROCm](https://img.shields.io/badge/Backend-ROCm-ED1C24)
![OpenVINO](https://img.shields.io/badge/Backend-OpenVINO-0071C5)
![SYCL](https://img.shields.io/badge/Backend-SYCL-7C3AED)
![API](https://img.shields.io/badge/API-OpenAI--compatible-111827)
![Service](https://img.shields.io/badge/Service-systemd%20user-F59E0B)
![Installer](https://img.shields.io/badge/Install-custom%20path-EC4899)
![License](https://img.shields.io/badge/License-MIT-10B981)
</div>

<div align="center">
  <a href="https://buymeacoffee.com/mirhh">
    <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/bmc-button.png" alt="Buy me a coffee" width="300">
  </a>
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

```text
OpenAI-compatible client
          |
          v
 llama-swap (localhost)
          |
          v
 llama.cpp
          |
          v
    GGUF model files
```

## Requirements

- Ubuntu, Debian, Fedora, RHEL, or another compatible x86-64 Linux system
- A working CPU install, or a supported GPU/runtime for your selected backend
- `sudo` access during installation
- Enough RAM and VRAM for the model and quantization you choose

The installer uses the known compatible releases `llama.cpp b9672` and
`llama-swap v226`. The separate update script checks for newer releases.
The default llama.cpp backend is `vulkan`. For CPU-only machines or simple VM
testing, use `LLAMA_CPP_BACKEND=cpu`; CPU installs use smaller defaults and no
GPU offload.

The installer can install required packages with `apt-get`, `dnf`, or `yum`.
Upstream llama.cpp Linux x64 release archives currently use `ubuntu` in their
file names, even when they can run on other compatible Linux distributions.

## Install

```bash
git clone https://github.com/hossbit/local-ai-server.git
cd local-ai-server
chmod +x ./*.sh
./install-local-ai.sh
```

The installer creates `~/.local/bin/localai`. Make sure `~/.local/bin` is in
your shell `PATH` so the command is available from any directory.

The installer asks where to install LocalAI:

```text
LocalAI install directory [~/ai]:
```

Press Enter to use the default `~/ai`. To choose the path without a prompt, set
`LOCALAI_DIR`:

```bash
LOCALAI_DIR=~/my-ai ./install-local-ai.sh
```

Or pass `--dir`:

```bash
./install-local-ai.sh --dir ~/my-ai
```

Choose a llama.cpp backend with `LLAMA_CPP_BACKEND`. The default is `vulkan`.

```bash
LLAMA_CPP_BACKEND=cpu ./install-local-ai.sh
LLAMA_CPP_BACKEND=vulkan ./install-local-ai.sh
LLAMA_CPP_BACKEND=rocm ./install-local-ai.sh
LLAMA_CPP_BACKEND=openvino ./install-local-ai.sh
LLAMA_CPP_BACKEND=sycl-fp16 ./install-local-ai.sh
LLAMA_CPP_BACKEND=sycl-fp32 ./install-local-ai.sh
```

Fedora and RHEL systems use the same upstream Linux x64 llama.cpp archives as
Ubuntu/Debian. If a selected backend cannot run because a runtime library is
missing, the installer stops after testing `llama-server --version` and tells
you to install the missing runtime or retry with another backend such as `cpu`.

CPU backend installs default to:

```text
LOCALAI_N_GPU_LAYERS=0
LOCALAI_CTX_SIZE=4096
```

The installer:

1. Installs required system packages.
2. Downloads the pinned llama.cpp b9672 backend archive and llama-swap v226.
3. Creates `bin`, `models`, the shared `localai.conf`, helper scripts, and the `localai` command inside the install directory.
4. Selects an available port, beginning at `11435`.
5. Installs a `~/.local/bin/localai` launcher and creates a systemd user service that points to the selected install directory.

The installer does not start the server automatically. If no `.gguf` files are
found in the models directory, it prints a warning because chat requests need a
model. Add at least one model, then start it with:

```bash
localai start
localai check
```

To start it automatically when you log in:

```bash
systemctl --user enable --now localai
```

## Add a model

Place one or more `.gguf` files in:

```text
~/ai/models
```

If you installed somewhere else, use that directory's `models` folder instead.

For example, with the Hugging Face CLI:

```bash
python3 -m pip install --user huggingface_hub
hf auth login

hf download bartowski/Qwen2.5-Coder-7B-Instruct-GGUF \
  Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf \
  --local-dir ~/ai/models
```

Some model repositories require a Hugging Face account and read token. See
[Hugging Face access tokens](https://huggingface.co/docs/hub/security-tokens).

The model ID exposed by the API is the filename without `.gguf`. For example:

```text
Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
```

becomes:

```text
Qwen2.5-Coder-7B-Instruct-Q4_K_M
```

## Choose a quantization

| Quantization | Relative quality | Relative memory use |
| --- | --- | --- |
| Q2_K | Lowest | Smallest |
| Q3_K_M | Good | Low |
| Q4_K_M | Recommended balance | Medium |
| Q5_K_M | Better | High |
| Q6_K | Very good | Higher |
| Q8_0 | Near FP16 | Highest |

`Q4_K_M` is a useful starting point for GPUs with limited VRAM. Actual memory
use also depends on model size, context length, and GPU-offloaded layers.

Embedding models, such as many `bge` or `e5` files, are for embeddings and
search-style workflows. For chat, choose an instruct/chat model such as a
`Qwen*-Instruct` GGUF file. `Q2_K` is smaller and easier to move around, but
quality is lower than `Q4_K_M`.

## Use the server

Read the selected port:

```bash
PORT=$(cat ~/ai/port)
```

For a custom install directory:

```bash
PORT=$(cat ~/my-ai/port)
```

List available models:

```bash
curl "http://127.0.0.1:${PORT}/v1/models"
```

Send a chat request:

```bash
MODEL="Qwen2.5-Coder-7B-Instruct-Q4_K_M"

curl "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"What is Linux?\"}
    ]
  }"
```

Python with the OpenAI SDK:

```python
from pathlib import Path
from openai import OpenAI

port = Path.home().joinpath("ai/port").read_text().strip()
client = OpenAI(base_url=f"http://127.0.0.1:{port}/v1", api_key="local")

response = client.chat.completions.create(
    model="Qwen2.5-Coder-7B-Instruct-Q4_K_M",
    messages=[{"role": "user", "content": "Hello!"}],
)

print(response.choices[0].message.content)
```

The local server does not validate `api_key`, but OpenAI client libraries
usually require a non-empty value.

## Service and helper commands

```bash
localai start
localai stop
localai restart
localai status
localai check
localai check --chat
localai logs
localai models
localai update
localai version
localai uninstall
```

`localai start`, `localai stop`, and `localai restart` show the service method,
service file, install directory, API endpoint, log path, and the exact
`systemctl` or helper script command being used. `localai status` also reports
the actual `llama-swap` process and listening port, which is more useful than
systemd's `active (exited)` wording for this helper service.

Example:

```text
LocalAI service details:
  method: systemd user service
  service: localai.service
  service file: ~/.config/systemd/user/localai.service
  install dir: ~/ai
  API: http://127.0.0.1:11435
  log: ~/ai/logs/llama-swap.log
Running: systemctl --user start localai
```

Set `LOCALAI_DIR` if you chose a custom install path and are running the
command before installation has created the launcher.

Direct-process logs are written to:

```text
~/ai/logs/llama-swap.log
```

## Configuration

Shared defaults live in:

```text
localai.conf          # source default
~/ai/localai.conf     # installed copy
```

This file contains commented settings for install paths, service name, release
versions, backend asset patterns, package lists, port, listen host, generated
config filenames, logs, PID files, and llama.cpp runtime defaults. Environment
variables still override the config for one command.

`rebuild-config.sh` creates `config.yaml` from every `.gguf` file in the
install directory's `models` folder. It runs automatically whenever the server
starts.

Default runtime settings are:

- Vulkan and other GPU-capable backends: context size `16384`, GPU layers `8`
- CPU backend: context size `4096`, GPU layers `0`
- KV cache: `q4_0`
- Idle model timeout: `900` seconds

Override context size or GPU layers for one start:

```bash
LOCALAI_CTX_SIZE=8192 LOCALAI_N_GPU_LAYERS=20 localai start
```

If you use systemd and want persistent overrides, add them with:

```bash
systemctl --user edit localai
```

Then enter:

```ini
[Service]
Environment=LOCALAI_CTX_SIZE=8192
Environment=LOCALAI_N_GPU_LAYERS=20
```

Apply the change:

```bash
systemctl --user daemon-reload
systemctl --user restart localai
```

## Update

Update installed components:

```bash
localai update
```

The updater checks GitHub for the latest compatible releases, refreshes the
installed helper scripts when run from the repository, updates outdated
components, and preserves models, the configured port, and runtime tuning such
as context size, GPU layers, threads, and cache settings. By default it starts
the server after an update, using the systemd user service when it is installed;
use `--no-start` to leave it stopped.

The updater keeps the installed llama.cpp backend. To switch backend during an
update, pass `LLAMA_CPP_BACKEND`:

```bash
LLAMA_CPP_BACKEND=cpu localai update
```

## Uninstall

Remove the user service and installed helper files:

```bash
localai uninstall
```

For a custom install directory:

```bash
LOCALAI_DIR=~/my-ai localai uninstall
```

By default the uninstaller keeps the install directory's `models` folder. To
remove downloaded models too:

```bash
localai uninstall --remove-models
```

For a custom install directory, either set `LOCALAI_DIR` or pass `--dir`:

```bash
localai uninstall --dir ~/my-ai
```

To also remove the shared `llama-swap` binary installed in `/usr/local/bin`:

```bash
localai uninstall --remove-llama-swap
```

## Troubleshooting

Check the configured port and models:

```bash
cat ~/ai/port
localai models
localai check
curl "http://127.0.0.1:$(cat ~/ai/port)/v1/models"
```

Replace `~/ai` with your selected install directory if needed.

Check GPU detection:

```bash
~/ai/bin/llama-server --list-devices
```

Check logs:

```bash
tail -n 100 ~/ai/logs/llama-swap.log
localai logs
```

If a Hugging Face download returns `401 Unauthorized`:

```bash
hf auth logout
hf auth login
hf auth whoami
```

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

## License

MIT License
