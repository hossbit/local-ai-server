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
PID_FILE="$AI_DIR/$LOCALAI_PID_FILE"

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

if kill -0 "$PID" 2>/dev/null; then
  COMMAND=$(ps -p "$PID" -o comm= 2>/dev/null || true)
  if [[ "$COMMAND" != *llama-swap* ]]; then
    rm -f "$PID_FILE"
    echo "Removed stale PID file; PID $PID belongs to ${COMMAND:-another process}."
    exit 0
  fi

  kill "$PID"

  for _ in {1..20}; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
  done

  if kill -0 "$PID" 2>/dev/null; then
    echo "Error: llama-swap (PID $PID) did not stop cleanly." >&2
    exit 1
  fi
fi

rm -f "$PID_FILE"
echo "LocalAI stopped"
