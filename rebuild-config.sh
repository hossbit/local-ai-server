#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
CONFIG="$AI_DIR/config.yaml"
MODELS_DIR="$AI_DIR/models"
BIN="$AI_DIR/bin/llama-server"

cat > "$CONFIG" <<CFG
healthCheckTimeout: 300
globalTTL: 900

models:
CFG

for MODEL in "$MODELS_DIR"/*.gguf; do
  [ -f "$MODEL" ] || continue
  NAME=$(basename "$MODEL" .gguf)

  cat >> "$CONFIG" <<MODELCFG

  $NAME:
    proxy: http://127.0.0.1:\${PORT}
    cmd: >
      $BIN
      --port \${PORT}
      -m $MODEL
      -ngl 10
      -t 0
      -c 32768
      --cache-type-k q8_0
      --cache-type-v q8_0

MODELCFG
done

echo "Generated $CONFIG"
