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

The installer does not start the server automatically. If no `.gguf` files are
found in the models directory, it prints a warning because chat requests need a
model. Add at least one model, then use the service commands below to start and
check LocalAI.

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

Most users only need these:

| Command | Purpose |
| --- | --- |
| `localai start` | Start the service. |
| `localai stop` | Unload loaded models, then stop the service. |
| `localai restart` | Restart the service. |
| `localai status` | Show service, process, API, and port status. |
| `localai check` | Check the API and model list. |
| `localai logs` | Follow LocalAI logs. |
| `localai models` | List installed `.gguf` models. |
| `localai load MODEL` | Warm one model, for example `localai load Qwen2.5-Coder-7B-Instruct-Q4_K_M`. |
| `localai unload MODEL` | Release one loaded model. |
| `localai unload all` | Release all loaded models. |
| `localai update` | Update installed components. |
| `localai version` | Show component versions. |
| `localai uninstall` | Remove helper files; models are kept by default. |

Advanced forms:

| Command | Purpose |
| --- | --- |
| `localai check --chat` | Also send a tiny chat request. |
| `localai load all` | Warm every model; use only when you have enough memory. |
| `localai update --no-start` | Update and leave the service stopped. |
| `LLAMA_CPP_BACKEND=cpu localai update` | Switch backend during update. |
| `LOCALAI_CTX_SIZE=8192 LOCALAI_N_GPU_LAYERS=20 localai start` | Override runtime settings for one start. |
| `localai uninstall --remove-models` | Also remove downloaded models. |
| `localai uninstall --dir ~/my-ai` | Uninstall from a custom directory. |
| `localai uninstall --remove-llama-swap` | Also remove the shared `llama-swap` binary. |

## Configuration

Shared defaults live in:

```text
localai.conf          # source default
~/ai/localai.conf     # installed copy
```

This file contains install paths, service names, port settings, logs, PID files,
and llama.cpp runtime defaults. Environment variables still override the config
for one command.

`rebuild-config.sh` creates `config.yaml` from every `.gguf` file in the
install directory's `models` folder. It runs automatically whenever the server
starts.

Default runtime settings are:

- Vulkan and other GPU-capable backends: context size `16384`, GPU layers `8`
- CPU backend: context size `4096`, GPU layers `0`
- KV cache: `q4_0`
- Idle model timeout: `900` seconds

Override context size or GPU layers for one start with the start command form
shown in the service command table.

## Troubleshooting

Check the configured port and models:

```bash
cat ~/ai/port
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
