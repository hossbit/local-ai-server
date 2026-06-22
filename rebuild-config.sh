#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
CONFIG="$AI_DIR/config.yaml"
MODELS_DIR="$AI_DIR/models"
BIN="$AI_DIR/bin/llama-server"
CTX_SIZE="${CTX_SIZE:-32768}"
N_GPU_LAYERS="${N_GPU_LAYERS:-10}"

if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || ((CTX_SIZE < 1)); then
  echo "Error: CTX_SIZE must be a positive integer." >&2
  exit 1
fi

if ! [[ "$N_GPU_LAYERS" =~ ^[0-9]+$ ]]; then
  echo "Error: N_GPU_LAYERS must be a non-negative integer." >&2
  exit 1
fi

mkdir -p "$MODELS_DIR"

cat > "$CONFIG" <<CFG
healthCheckTimeout: 300
globalTTL: 900

models:
CFG

MODEL_COUNT=0
for MODEL in "$MODELS_DIR"/*.gguf; do
  [ -f "$MODEL" ] || continue
  NAME=$(basename "$MODEL" .gguf)
  if [[ "$NAME" == *['"$`\']* ]]; then
    echo "Skipping unsupported model filename: $(basename "$MODEL")" >&2
    continue
  fi
  MODEL_COUNT=$((MODEL_COUNT + 1))

  cat >> "$CONFIG" <<MODELCFG

  "$NAME":
    proxy: http://127.0.0.1:\${PORT}
    cmd: >
      "$BIN"
      --port \${PORT}
      --model "$MODEL"
      --n-gpu-layers $N_GPU_LAYERS
      -t 0
      --ctx-size $CTX_SIZE
      --cache-type-k q8_0
      --cache-type-v q8_0

MODELCFG
done

echo "Generated $CONFIG with $MODEL_COUNT model(s)."
