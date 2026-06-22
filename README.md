# Local AI Server

Run GGUF language models locally with
[llama.cpp](https://github.com/ggml-org/llama.cpp),
Vulkan GPU acceleration, and
[llama-swap](https://github.com/mostlygeek/llama-swap).
The server exposes an OpenAI-compatible API and discovers models placed in
`~/ai/models`.

## What it provides

- OpenAI-compatible chat and completion endpoints
- Vulkan acceleration on supported NVIDIA, AMD, and Intel GPUs
- Automatic discovery of `.gguf` model files
- On-demand model loading and switching through llama-swap
- A systemd user service
- Update, start, stop, and configuration helper scripts

```text
OpenAI-compatible client
          |
          v
 llama-swap (localhost)
          |
          v
 llama.cpp + Vulkan
          |
          v
    GGUF model files
```

## Requirements

- Ubuntu or Debian on an x86-64 machine
- A Vulkan-capable GPU and working Vulkan driver
- `sudo` access during installation
- Enough RAM and VRAM for the model and quantization you choose

The installer uses the known compatible releases `llama.cpp b9672` and
`llama-swap v226`. The separate update script checks for newer releases.

## Install

```bash
git clone https://github.com/hossbit/localai.git
cd localai
chmod +x ./*.sh
./install-local-ai.sh
```

The installer:

1. Installs required system packages.
2. Downloads the pinned llama.cpp b9672 and llama-swap v226 releases.
3. Creates `~/ai/bin`, `~/ai/models`, and the helper scripts.
4. Selects an available port, beginning at `11435`.
5. Creates a systemd user service.

The installer does not start the server automatically. Add at least one model,
then start it with:

```bash
systemctl --user start localai
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

## Use the server

Read the selected port:

```bash
PORT=$(cat ~/ai/port)
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
# Start, stop, restart, and inspect the systemd service
systemctl --user start localai
systemctl --user stop localai
systemctl --user restart localai
systemctl --user status localai

# Follow service output
journalctl --user -u localai -f

# Run the helpers directly
~/ai/start.sh
~/ai/stop.sh
~/ai/rebuild-config.sh
~/ai/update-local-ai.sh
```

Direct-process logs are written to:

```text
~/ai/logs/llama-swap.log
```

## Configuration

`rebuild-config.sh` creates `~/ai/config.yaml` from every `.gguf` file in
`~/ai/models`. It runs automatically whenever the server starts.

The defaults are:

- Context size: `32768`
- GPU layers: `10`
- KV cache: `q8_0`
- Idle model timeout: `900` seconds

Override context size or GPU layers for one start:

```bash
CTX_SIZE=8192 N_GPU_LAYERS=20 ~/ai/start.sh
```

If you use systemd and want persistent overrides, add them with:

```bash
systemctl --user edit localai
```

Then enter:

```ini
[Service]
Environment=CTX_SIZE=8192
Environment=N_GPU_LAYERS=20
```

Apply the change:

```bash
systemctl --user daemon-reload
systemctl --user restart localai
```

## Update

From the cloned repository:

```bash
./update-local-ai.sh
```

Or use the installed copy:

```bash
~/ai/update-local-ai.sh
```

The updater checks GitHub for the latest compatible releases, refreshes the
installed helper scripts when run from the repository, updates outdated
components, and preserves models and the configured port. By default it starts
the server after an update; use `--no-start` to leave it stopped.

## Troubleshooting

Check the configured port and models:

```bash
cat ~/ai/port
ls -lh ~/ai/models
curl "http://127.0.0.1:$(cat ~/ai/port)/v1/models"
```

Check GPU detection:

```bash
~/ai/bin/llama-server --list-devices
```

Check logs:

```bash
tail -n 100 ~/ai/logs/llama-swap.log
journalctl --user -u localai -n 100 --no-pager
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

## License

MIT
