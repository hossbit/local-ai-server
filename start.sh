#!/usr/bin/env bash
set -euo pipefail
AI_DIR="$HOME/ai"
PORT=$(cat "$AI_DIR/port")

"$AI_DIR/rebuild-config.sh"

exec llama-swap --listen ":${PORT}" --config "$AI_DIR/config.yaml"
