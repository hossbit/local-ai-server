#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
BIN_DIR="$AI_DIR/bin"
MODELS_DIR="$AI_DIR/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_VERSION="b9672"
LLAMA_SWAP_VERSION="v226"
LLAMA_CPP_URL="https://github.com/ggml-org/llama.cpp/releases/download/b9672/llama-b9672-bin-ubuntu-vulkan-x64.tar.gz"
LLAMA_SWAP_URL="https://github.com/mostlygeek/llama-swap/releases/download/v226/llama-swap_226_linux_amd64.tar.gz"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

cleanup_bin_artifacts() {
  log "Cleaning old llama.cpp folders and archives"

  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name llama.cpp -exec rm -rf -- {} +
  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' -delete
}

[ "$(uname -m)" = "x86_64" ] || fail "this installer currently supports x86_64 Linux only"

mkdir -p "$AI_DIR" "$BIN_DIR" "$MODELS_DIR"

###############################################################################
# INSTALL SYSTEM DEPENDENCIES
###############################################################################

log "Installing system dependencies"

sudo apt-get update
sudo apt-get install -y ca-certificates curl iproute2 tar

###############################################################################
# DOWNLOAD RELEASE ARCHIVES
###############################################################################

DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

log "Downloading llama.cpp $LLAMA_CPP_VERSION"

curl -4 -fL --retry 3 --retry-delay 2 \
  --output "$DOWNLOAD_DIR/llama.cpp.tar.gz" \
  "$LLAMA_CPP_URL" \
  || fail "failed to download llama.cpp"

log "Downloading llama-swap $LLAMA_SWAP_VERSION"

curl -4 -fL --retry 3 --retry-delay 2 \
  --output "$DOWNLOAD_DIR/llama-swap.tar.gz" \
  "$LLAMA_SWAP_URL" \
  || fail "failed to download llama-swap"

if [ -x "$AI_DIR/stop.sh" ] && [ -f "$AI_DIR/llama-swap.pid" ]; then
  log "Stopping the existing LocalAI service"
  "$AI_DIR/stop.sh"
fi

###############################################################################
# INSTALL LLAMA.CPP
###############################################################################

log "Installing llama.cpp"

mkdir -p "$DOWNLOAD_DIR/llama.cpp"
tar -xzf "$DOWNLOAD_DIR/llama.cpp.tar.gz" \
  -C "$DOWNLOAD_DIR/llama.cpp" \
  || fail "failed to extract llama.cpp"

LLAMA_SERVER_REAL=$(
  find "$DOWNLOAD_DIR/llama.cpp" -type f -name llama-server -print -quit
)
[ -n "$LLAMA_SERVER_REAL" ] || fail "llama-server was not found in the archive"

LLAMA_RELEASE_DIR=$(dirname "$LLAMA_SERVER_REAL")
rm -rf "$BIN_DIR/llama.cpp"
mv "$LLAMA_RELEASE_DIR" "$BIN_DIR/llama.cpp"

cat > "$DOWNLOAD_DIR/llama-server" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$BIN_DIR/llama.cpp:\${LD_LIBRARY_PATH:-}"
exec "$BIN_DIR/llama.cpp/llama-server" "\$@"
EOF

install -m755 "$DOWNLOAD_DIR/llama-server" "$BIN_DIR/llama-server"
cleanup_bin_artifacts

###############################################################################
# INSTALL LLAMA-SWAP
###############################################################################

log "Installing llama-swap"

mkdir -p "$DOWNLOAD_DIR/llama-swap"
tar -xzf "$DOWNLOAD_DIR/llama-swap.tar.gz" \
  -C "$DOWNLOAD_DIR/llama-swap" \
  || fail "failed to extract llama-swap"

LLAMA_SWAP_REAL=$(
  find "$DOWNLOAD_DIR/llama-swap" -type f -name llama-swap -print -quit
)
[ -n "$LLAMA_SWAP_REAL" ] || fail "llama-swap was not found in the archive"

sudo install -m755 "$LLAMA_SWAP_REAL" /usr/local/bin/llama-swap

###############################################################################
# SELECT API PORT
###############################################################################

if [ ! -f "$AI_DIR/port" ]; then
  PORT=11435
  while ss -ltn | awk '{print $4}' | grep -q ":${PORT}$"; do
    PORT=$((PORT + 1))
  done
  echo "$PORT" > "$AI_DIR/port"
fi

###############################################################################
# INSTALL HELPER SCRIPTS AND SYSTEMD SERVICE
###############################################################################

log "Installing helper scripts and systemd service"

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/localai.service" <<'EOF'
[Unit]
Description=LocalAI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/ai/start.sh
ExecStop=%h/ai/stop.sh

[Install]
WantedBy=default.target
EOF

install -m755 "$SCRIPT_DIR/start.sh" "$AI_DIR/start.sh"
install -m755 "$SCRIPT_DIR/stop.sh" "$AI_DIR/stop.sh"
install -m755 "$SCRIPT_DIR/rebuild-config.sh" "$AI_DIR/rebuild-config.sh"
install -m755 "$SCRIPT_DIR/update-local-ai.sh" "$AI_DIR/update-local-ai.sh"

if ! systemctl --user daemon-reload; then
  echo "Warning: could not reload the systemd user manager." >&2
  echo "You can still use the scripts in $AI_DIR directly." >&2
fi

echo
echo "============================================================"
echo " LocalAI installation completed"
echo "============================================================"
echo
echo "Service commands:"
echo
echo "  Start service:"
echo "    systemctl --user start localai"
echo
echo "  Stop service:"
echo "    systemctl --user stop localai"
echo
echo "  Restart service:"
echo "    systemctl --user restart localai"
echo
echo "  Check status:"
echo "    systemctl --user status localai"
echo
echo "  View logs:"
echo "    journalctl --user -u localai -f"
echo
echo "  Enable auto-start on login:"
echo "    systemctl --user enable localai"
echo
echo "  Disable auto-start:"
echo "    systemctl --user disable localai"
echo
echo "Helper scripts:"
echo
echo "  Start manually:"
echo "    ~/ai/start.sh"
echo
echo "  Stop manually:"
echo "    ~/ai/stop.sh"
echo
echo "  Rebuild config:"
echo "    ~/ai/rebuild-config.sh"
echo
echo "  Update components:"
echo "    ~/ai/update-local-ai.sh"
echo
echo "API endpoint:"
echo "  http://localhost:$(cat "$AI_DIR/port")"
echo
echo "Models directory:"
echo "  $MODELS_DIR"
echo
echo "Current versions:"
"$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}'
llama-swap --version 2>&1 | awk 'NR == 1 {print; exit}'
echo
echo "============================================================"
