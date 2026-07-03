#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localai.conf"
elif [ -f "$SCRIPT_DIR/localai.conf" ]; then
  # shellcheck source=localai.conf
  . "$SCRIPT_DIR/localai.conf"
else
  echo "Error: localai.conf not found." >&2
  exit 1
fi

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
  elif [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
    cd "$SCRIPT_DIR/.." && pwd
  elif [ -f "$SCRIPT_DIR/install-local-ai.sh" ]; then
    expand_path "$LOCALAI_DEFAULT_DIR"
  else
    printf '%s\n' "$SCRIPT_DIR"
  fi
}

AI_DIR="$(resolve_ai_dir)"
BIN_DIR="$AI_DIR/$LOCALAI_BIN_SUBDIR"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
PORT_FILE="$CONF_DIR/$LOCALAI_PORT_FILE"
PID_FILE="$CONF_DIR/$LOCALAI_PID_FILE"
LOG_FILE="$AI_DIR/$LOCALAI_LOGS_SUBDIR/llama-swap.log"
CONFIG_FILE="$CONF_DIR/$LOCALAI_CONFIG_FILE"

mkdir -p "$CONF_DIR" "$AI_DIR/$LOCALAI_LOGS_SUBDIR"

if [ -z "$LLAMA_SWAP_BIN" ]; then
  echo "Error: llama-swap is not installed or is not in PATH." >&2
  exit 1
fi

if [ ! -x "$BIN_DIR/llama-server" ]; then
  echo "Error: $BIN_DIR/llama-server is missing or not executable." >&2
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

"$BIN_DIR/rebuild-config.sh"

if ! find "$AI_DIR/$LOCALAI_MODELS_SUBDIR" -maxdepth 1 -type f -name '*.gguf' -print -quit | grep -q .; then
  echo "No GGUF models found in $AI_DIR/$LOCALAI_MODELS_SUBDIR."
  echo "LocalAI will start, but chat requests need a model file and a matching model name."
fi

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
echo "Use 'localai models' to see model names, and 'localai check' to verify the API."
