#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
PORT_FILE="$AI_DIR/port"
PID_FILE="$AI_DIR/llama-swap.pid"
LOG_FILE="$AI_DIR/logs/llama-swap.log"
CONFIG_FILE="$AI_DIR/config.yaml"
LLAMA_SWAP_BIN="${LLAMA_SWAP_BIN:-$(command -v llama-swap || true)}"

mkdir -p "$AI_DIR/logs"

if [ -z "$LLAMA_SWAP_BIN" ]; then
  echo "Error: llama-swap is not installed or is not in PATH." >&2
  exit 1
fi

if [ ! -x "$AI_DIR/bin/llama-server" ]; then
  echo "Error: $AI_DIR/bin/llama-server is missing or not executable." >&2
  exit 1
fi

if [ ! -f "$PORT_FILE" ]; then
  echo "11435" > "$PORT_FILE"
fi

PORT=$(<"$PORT_FILE")
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  echo "Error: invalid port in $PORT_FILE: $PORT" >&2
  exit 1
fi

if [ -f "$PID_FILE" ]; then
  PID=$(<"$PID_FILE")
  if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
    COMMAND=$(ps -p "$PID" -o comm= 2>/dev/null || true)
    if [[ "$COMMAND" == *llama-swap* ]]; then
      echo "LocalAI is already running (PID $PID) on port $PORT."
      exit 0
    fi
  fi
  rm -f "$PID_FILE"
fi

"$AI_DIR/rebuild-config.sh"

nohup "$LLAMA_SWAP_BIN" \
  --listen "127.0.0.1:${PORT}" \
  --config "$CONFIG_FILE" \
  > "$LOG_FILE" 2>&1 &

PID=$!
echo "$PID" > "$PID_FILE"

sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "Error: llama-swap failed to start. See $LOG_FILE" >&2
  exit 1
fi

echo "LocalAI started at http://127.0.0.1:${PORT} (PID $PID)"
