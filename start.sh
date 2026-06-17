#!/usr/bin/env bash
set -euo pipefail
AI_DIR="$HOME/ai"
PORT=$(cat "$AI_DIR/port")

mkdir -p "$AI_DIR/logs"

"$AI_DIR/rebuild-config.sh"

nohup llama-swap --listen ":${PORT}" --config "$AI_DIR/config.yaml" > "$AI_DIR/logs/llama-swap.log" 2>&1 &

echo $! > "$AI_DIR/llama-swap.pid"
echo "LocalAI started on port ${PORT}"
