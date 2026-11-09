#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bootstrap.sh" 2>/dev/null ||
  . "$SCRIPT_DIR/../lib/bootstrap.sh" 2>/dev/null ||
  { echo "Error: missing LocalAI bootstrap library: lib/bootstrap.sh" >&2; exit 1; }

AI_DIR="$(resolve_ai_dir)"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
PID_FILE="$CONF_DIR/$LOCALAI_PID_FILE"
PID_START_FILE="$CONF_DIR/$LOCALAI_PID_FILE.start"
PORT_FILE="$CONF_DIR/$LOCALAI_PORT_FILE"

api_base_url() {
  api_base_url_for_port_file "$PORT_FILE"
}

unload_loaded_models() {
  local base running_count

  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  base="$(api_base_url)"
  api_auth_curl_args
  running_count="$(
    curl "${AUTH_CURL_ARGS[@]}" --max-time 5 -fsS "$base/running" 2>/dev/null |
      jq '[.running[]?] | length' 2>/dev/null
  )" || return 0

  if [[ "$running_count" =~ ^[0-9]+$ ]] && ((running_count > 0)); then
    echo "Unloading loaded model(s) before stop..."
    curl "${AUTH_CURL_ARGS[@]}" --max-time 30 -fsS -X POST "$base/api/models/unload" >/dev/null 2>&1 || \
      echo "Warning: failed to unload loaded model(s) before stop." >&2
  fi
}

if [ ! -f "$PID_FILE" ]; then
  echo "LocalAI is not running (no PID file)."
  exit 0
fi

PID=$(<"$PID_FILE")
if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
  rm -f "$PID_FILE"
  echo "Removed invalid PID file."
  exit 0
fi

if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
  COMMAND=$(ps -p "$PID" -o comm= 2>/dev/null || true)
  if [[ "$COMMAND" != *llama-swap* ]]; then
    rm -f "$PID_FILE" "$PID_START_FILE"
    echo "Removed stale PID file; PID $PID belongs to ${COMMAND:-another process}."
    exit 0
  fi

  unload_loaded_models

  kill "$PID"

  STOP_TIMEOUT="${LOCALAI_STOP_TIMEOUT:-60}"
  [[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || STOP_TIMEOUT=60
  STOP_ITERATIONS=$((STOP_TIMEOUT * 4))
  for ((i = 0; i < STOP_ITERATIONS; i++)); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
  done

  if kill -0 "$PID" 2>/dev/null; then
    echo "Error: llama-swap (PID $PID) did not stop within ${STOP_TIMEOUT}s." >&2
    exit 1
  fi
fi

rm -f "$PID_FILE" "$PID_START_FILE"
echo "LocalAI stopped"
