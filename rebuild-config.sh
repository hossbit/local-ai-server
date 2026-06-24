#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
CONFIG="$AI_DIR/config.yaml"
MODELS_DIR="$AI_DIR/models"
BIN="$AI_DIR/bin/llama-server"
CTX_SIZE="${CTX_SIZE:-16384}"
N_GPU_LAYERS="${N_GPU_LAYERS:-8}"
THREADS="${THREADS:-6}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"

if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || ((CTX_SIZE < 1)); then
  echo "Error: CTX_SIZE must be a positive integer." >&2
  exit 1
fi

if ! [[ "$N_GPU_LAYERS" =~ ^[0-9]+$ ]]; then
  echo "Error: N_GPU_LAYERS must be a non-negative integer." >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
  echo "Error: THREADS must be a non-negative integer." >&2
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
      -t $THREADS
      --ctx-size $CTX_SIZE
      --cache-type-k $CACHE_TYPE_K
      --cache-type-v $CACHE_TYPE_V

MODELCFG
done

echo "Generated $CONFIG with $MODEL_COUNT model(s)."
