# Local AI Server (llama.cpp + Vulkan + llama-swap)

Run OpenAI-compatible local LLMs using llama.cpp Vulkan acceleration and llama-swap model routing.

## Features

* OpenAI-compatible API
* Vulkan GPU acceleration
* Hot model switching with llama-swap
* Supports GGUF models from Hugging Face
* Multiple model configurations

---

## Requirements

* Linux
* Vulkan-compatible GPU
* curl
* wget
* Git

---

## Installation

Clone the repository and run:

```bash
chmod +x install-local-ai.sh
./install-local-ai.sh
```

This installs:

* llama.cpp
* llama-swap
* required dependencies
* service scripts

---

## Download Models

Create the models directory:

```bash
mkdir -p ~/ai/models
```

### Login to Hugging Face

Install the CLI:

```bash
pip install -U huggingface_hub
```

Login:

```bash
hf auth login
```

Create a Read token at:

https://huggingface.co/settings/tokens

and paste it when prompted.

### Download a GGUF Model

Example: Qwen3 8B Q4_K_M

```bash
hf download bartowski/Qwen3-8B-GGUF \
Qwen3-8B-Q4_K_M.gguf \
--local-dir ~/ai/models
```

### List Available Files

```bash
wget -qO- https://huggingface.co/api/models/bartowski/Qwen3-8B-GGUF \
| grep -o '"rfilename":"[^"]*"' \
| cut -d'"' -f4
```

---

## Configure Models

Edit:

```bash
~/ai/config.yaml
```

Example:

```yaml
models:
  qwen3-8b:
    cmd: >
      llama-server
      -m /home/$USER/ai/models/Qwen3-8B-Q4_K_M.gguf
      --host 127.0.0.1
      --port ${PORT}
      -ngl 999
```

---

## Start Server

```bash
~/ai/start.sh
```

Verify:

```bash
curl http://localhost:11435/v1/models
```

---

## Test Chat API

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

## Stop Server

```bash
~/ai/stop.sh
```

---

## Restart After Model Changes

```bash
~/ai/rebuild-config.sh
~/ai/stop.sh
~/ai/start.sh
```

---

## API Endpoints

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
* Custom applications

---

## Troubleshooting

### Unauthorized Download (401)

Login again:

```bash
hf auth login
```

Verify:

```bash
hf auth whoami
```

### Model Not Found

Check:

```bash
ls -lh ~/ai/models
```

### Server Not Running

Check logs:

```bash
ps aux | grep llama
ps aux | grep llama-swap
```


## Hugging Face Setup

GGUF models are downloaded from Hugging Face.

### Install Required Tools

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install git-lfs pipx -y
```

Install the Hugging Face CLI:

```bash
pipx install huggingface_hub
```

Verify installation:

```bash
hf --version
```

### Create a Hugging Face Account

Register at:

https://huggingface.co

### Generate an Access Token

1. Go to https://huggingface.co/settings/tokens
2. Click **New Token**
3. Give it a name (e.g. `local-ai`)
4. Select **Read** permission
5. Create the token
6. Copy the token immediately

A Read token is sufficient for downloading public and gated models.

### Login

```bash
hf auth login
```

Paste your token when prompted:

```text
Enter your token (input will not be visible):
```

When asked:

```text
Add token as git credential? [y/N]:
```

You can safely answer:

```text
N
```

Expected output:

```text
Login successful.
The current active token is: <token-name>
```

### Verify Login

```bash
hf auth whoami
```

Example:

```text
mir
```

### Where Is the Token Stored?

Active token:

```bash
~/.cache/huggingface/token
```

Saved tokens:

```bash
~/.cache/huggingface/stored_tokens
```

Show active token:

```bash
cat ~/.cache/huggingface/token
```

### Logout

```bash
hf auth logout
```

### Download a Model

Example:

```bash
hf download bartowski/Qwen3-8B-GGUF \
Qwen3-8B-Q4_K_M.gguf \
--local-dir ~/ai/models
```

### Download Gated Models

Some models require accepting a license before download.

Example:

* Llama models
* Gemma models
* Some Mistral variants

Visit the model page and click **Accept License** before downloading.

### Troubleshooting

#### Unauthorized (401)

Login again:

```bash
hf auth logout
hf auth login
```

#### Check Current User

```bash
hf auth whoami
```

#### List Downloaded Models

```bash
ls -lh ~/ai/models
```

## Finding Available GGUF Files

Before downloading a model, you can list all GGUF files available in a Hugging Face repository.

### Example: Qwen3 8B

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

### Download a Selected Model

Example:

```bash
hf download bartowski/Qwen_Qwen3-8B-GGUF \
Qwen3-8B-Q4_K_M.gguf \
--local-dir ~/ai/models
```

### Generic Command

Replace `<repository>` with any Hugging Face GGUF repository:

```bash
wget -qO- https://huggingface.co/api/models/<repository> \
| grep -o '"rfilename":"[^"]*"' \
| cut -d'"' -f4
```

Examples:

```bash
wget -qO- https://huggingface.co/api/models/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF \
| grep -o '"rfilename":"[^"]*"' \
| cut -d'"' -f4
```

```bash
wget -qO- https://huggingface.co/api/models/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF \
| grep -o '"rfilename":"[^"]*"' \
| cut -d'"' -f4
```

### Recommended Quantizations

| Quant  | Quality           | Memory Usage |
| ------ | ----------------- | ------------ |
| Q2_K   | Lowest            | Smallest     |
| Q3_K_M | Good              | Low          |
| Q4_K_M | Recommended       | Medium       |
| Q5_K_M | Better            | Higher       |
| Q6_K   | Very Good         | High         |
| Q8_0   | Near FP16 Quality | Very High    |

For a 4 GB RTX 3050, **Q4_K_M** is usually the best balance of quality, speed, and memory usage.

