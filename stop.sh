#!/usr/bin/env bash
set -euo pipefail
pkill -f llama-swap || true
pkill -f llama-server || true
rm -f "$HOME/ai/llama-swap.pid"
echo "LocalAI stopped"
