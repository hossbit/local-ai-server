#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
PID_FILE="$AI_DIR/llama-swap.pid"

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
