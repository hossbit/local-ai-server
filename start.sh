#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=localai.conf
. "$SCRIPT_DIR/localai.conf"

expand_path() {
  local value="$1"
  if [[ "$value" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "${value:0:2}" == "~/" ]]; then
    printf '%s/%s\n' "$HOME" "${value:2}"
  else
    printf '%s\n' "$value"
  fi
}

resolve_ai_dir() {
  if [ -n "${LOCALAI_DIR:-}" ]; then
    expand_path "$LOCALAI_DIR"
  elif [ -f "$SCRIPT_DIR/install-local-ai.sh" ]; then
    expand_path "$LOCALAI_DEFAULT_DIR"
  else
    printf '%s\n' "$SCRIPT_DIR"
  fi
}

AI_DIR="$(resolve_ai_dir)"
PORT_FILE="$AI_DIR/$LOCALAI_PORT_FILE"
PID_FILE="$AI_DIR/$LOCALAI_PID_FILE"
LOG_FILE="$AI_DIR/$LOCALAI_LOGS_SUBDIR/llama-swap.log"
CONFIG_FILE="$AI_DIR/$LOCALAI_CONFIG_FILE"

mkdir -p "$AI_DIR/$LOCALAI_LOGS_SUBDIR"

if [ -z "$LLAMA_SWAP_BIN" ]; then
  echo "Error: llama-swap is not installed or is not in PATH." >&2
  exit 1
fi

if [ ! -x "$AI_DIR/$LOCALAI_BIN_SUBDIR/llama-server" ]; then
  echo "Error: $AI_DIR/$LOCALAI_BIN_SUBDIR/llama-server is missing or not executable." >&2
  exit 1
fi

if [ ! -f "$PORT_FILE" ]; then
  echo "$LOCALAI_DEFAULT_PORT" > "$PORT_FILE"
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
  --listen "${LOCALAI_LISTEN_HOST}:${PORT}" \
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

echo "LocalAI started at http://${LOCALAI_LISTEN_HOST}:${PORT} (PID $PID)"
