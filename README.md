# Local AI Server

Run local GGUF LLMs with **llama.cpp**, **Vulkan GPU acceleration**, and **llama-swap** using an OpenAI-compatible API.

![Linux](https://img.shields.io/badge/Linux-Ubuntu-orange)
![llama.cpp](https://img.shields.io/badge/llama.cpp-Vulkan-blue)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

* OpenAI-compatible API
* Vulkan GPU acceleration
* Automatic model discovery
* Hot model switching with llama-swap
* Supports any GGUF model
* Hugging Face integration
* Systemd service support
* Works with Continue, Open WebUI, LibreChat, AnythingLLM, and OpenAI SDKs

---

## Architecture

```text
Client
  │
  ▼
llama-swap :11435
  │
  ├── Qwen3
  ├── Qwen Coder
  ├── DeepSeek
  ├── Gemma
  └── Any GGUF Model
          │
          ▼
     llama.cpp
          │
          ▼
      Vulkan GPU
```

---

## Requirements

### Operating System

* Ubuntu Linux
* Debian Linux

### Hardware

* Vulkan-compatible GPU
* NVIDIA, AMD, or Intel GPU

### Tested Hardware

* Ubuntu 26.04
* Intel Iris Xe
* NVIDIA RTX 3050 Laptop 4GB
* Vulkan Backend

---

# Quick Start

Clone the repository:

```bash
git clone https://github.com/hossbit/localai.git
cd localai
```

Run the installer:

```bash
chmod +x install-local-ai.sh
./install-local-ai.sh
```

The installer automatically:

* Downloads llama.cpp Vulkan binaries
* Installs llama-swap
* Creates configuration files
* Creates start/stop scripts
* Creates a systemd service

---

# Hugging Face Setup

GGUF models are downloaded from Hugging Face.

## Install Required Tools

```bash
sudo apt update
sudo apt install git-lfs pipx -y

pipx install huggingface_hub
```

Verify:

```bash
hf --version
```

---

## Create a Hugging Face Account

Register:

https://huggingface.co

---

## Create an Access Token

Open:

https://huggingface.co/settings/tokens

Create a token with:

```text
Read
```

permission.

Copy the token.

---

## Login

```bash
hf auth login
```

Paste your token when prompted.

Verify:

```bash
hf auth whoami
```

Example:

```text
hossbit
```

---

## Token Locations

Active token:

```bash
~/.cache/huggingface/token
```

Stored tokens:

```bash
~/.cache/huggingface/stored_tokens
```

Show active token:

```bash
cat ~/.cache/huggingface/token
```

Logout:

```bash
hf auth logout
```

---

# Finding Available GGUF Files

Example:

```bash
wget -qO- https://huggingface.co/api/models/bartowski/Qwen_Qwen3-8B-GGUF \
| grep -o '"rfilename":"[^"]*"' \
| cut -d'"' -f4
```

Example output:

```text
Qwen3-8B-Q2_K.gguf
Qwen3-8B-Q3_K_M.gguf
Qwen3-8B-Q4_K_M.gguf
Qwen3-8B-Q5_K_M.gguf
Qwen3-8B-Q6_K.gguf
Qwen3-8B-Q8_0.gguf
```

---

# Download Models

## Qwen3 8B

```bash
hf download bartowski/Qwen_Qwen3-8B-GGUF \
Qwen3-8B-Q4_K_M.gguf \
--local-dir ~/ai/models
```

## Qwen2.5 Coder 7B

```bash
hf download bartowski/Qwen2.5-Coder-7B-Instruct-GGUF \
Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf \
--local-dir ~/ai/models
```

## DeepSeek R1 Distill

```bash
hf download bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF \
DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf \
--local-dir ~/ai/models
```

---

# Recommended Quantizations

| Quant  | Quality     | Memory   |
| ------ | ----------- | -------- |
| Q2_K   | Lowest      | Smallest |
| Q3_K_M | Good        | Low      |
| Q4_K_M | Recommended | Medium   |
| Q5_K_M | Better      | High     |
| Q6_K   | Very Good   | Higher   |
| Q8_0   | Near FP16   | Highest  |

For GPUs with 4 GB VRAM:

```text
Q4_K_M
```

is usually the best balance between quality and speed.

---

# Start Server

```bash
~/ai/start.sh
```

Verify:

```bash
curl http://localhost:11435/v1/models
```

Expected output:

```json
{
  "data": [
    {
      "id": "qwen3-8b"
    }
  ]
}
```

---

# Stop Server

```bash
~/ai/stop.sh
```

---

# Restart After Model Changes

```bash
~/ai/rebuild-config.sh
~/ai/stop.sh
~/ai/start.sh
```

---

# Test Chat API

```bash
curl http://localhost:11435/v1/chat/completions \
-H "Content-Type: application/json" \
-d '{
  "model":"qwen3-8b",
  "messages":[
    {
      "role":"user",
      "content":"What is Linux?"
    }
  ]
}'
```

---

# Python Example

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="local"
)

response = client.chat.completions.create(
    model="qwen3-8b",
    messages=[
        {"role":"user","content":"Hello"}
    ]
)

print(response.choices[0].message.content)
```

---

# Continue IDE

Example configuration:

```json
{
  "title": "Qwen3",
  "provider": "openai",
  "model": "qwen3-8b",
  "apiBase": "http://localhost:11435/v1",
  "apiKey": "local"
}
```

---

# API Endpoints

```text
GET  /v1/models
POST /v1/chat/completions
POST /v1/completions
```

Compatible with:

* OpenAI SDK
* Continue
* Open WebUI
* LibreChat
* AnythingLLM
* Custom Applications

---

# Systemd Service

Enable automatic startup:

```bash
systemctl --user enable --now llama-swap
```

Check status:

```bash
systemctl --user status llama-swap
```

Restart:

```bash
systemctl --user restart llama-swap
```

Stop:

```bash
systemctl --user stop llama-swap
```

---

# Troubleshooting

## Unauthorized Download (401)

```bash
hf auth logout
hf auth login
```

Verify:

```bash
hf auth whoami
```

---

## Model Not Found

```bash
ls -lh ~/ai/models
```

---

## Check Available Models

```bash
curl http://localhost:11435/v1/models
```

---

## Check Running Processes

```bash
ps aux | grep llama
ps aux | grep llama-swap
```

---

## Check GPU Detection

```bash
~/ai/bin/llama-server --list-devices
```

Example:

```text
Vulkan0: Intel Iris Xe
Vulkan1: NVIDIA GeForce RTX 3050 Laptop GPU
```

---

# License

MIT License
