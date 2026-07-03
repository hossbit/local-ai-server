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
source_localai_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: common.sh" >&2
  exit 1
}
source_localai_common

AI_DIR="$(resolve_ai_dir)"
BIN_DIR="$AI_DIR/$LOCALAI_BIN_SUBDIR"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
PORT_FILE="$CONF_DIR/$LOCALAI_PORT_FILE"
PID_FILE="$CONF_DIR/$LOCALAI_PID_FILE"
PID_START_FILE="$CONF_DIR/$LOCALAI_PID_FILE.start"
LOG_FILE="$AI_DIR/$LOCALAI_LOGS_SUBDIR/llama-swap.log"
CONFIG_FILE="$CONF_DIR/$LOCALAI_CONFIG_FILE"
resolve_llama_swap_paths

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
  if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    COMMAND=$(ps -p "$PID" -o comm= 2>/dev/null || true)
    if [[ "$COMMAND" == *llama-swap* ]]; then
      echo "LocalAI is already running (PID $PID) on port $PORT."
      exit 0
    fi
  fi
  rm -f "$PID_FILE" "$PID_START_FILE"
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
process_start_time "$PID" > "$PID_START_FILE"

for _ in {1..30}; do
  if ! pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
    rm -f "$PID_FILE" "$PID_START_FILE"
    echo "Error: llama-swap failed to start. See $LOG_FILE" >&2
    exit 1
  fi
  if command -v curl >/dev/null 2>&1 &&
    curl --max-time 2 -fsS "http://${LOCALAI_LISTEN_HOST}:${PORT}/running" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! command -v curl >/dev/null 2>&1 ||
  ! curl --max-time 2 -fsS "http://${LOCALAI_LISTEN_HOST}:${PORT}/running" >/dev/null 2>&1; then
  echo "Error: llama-swap started but API did not become ready at http://${LOCALAI_LISTEN_HOST}:${PORT}/running. See $LOG_FILE" >&2
  exit 1
fi

echo "LocalAI started at http://${LOCALAI_LISTEN_HOST}:${PORT} (PID $PID)"
echo "Use 'localai models' to see model names, and 'localai check' to verify the API."
