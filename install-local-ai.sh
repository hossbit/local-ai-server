#!/usr/bin/env bash
set -euo pipefail

AI_DIR="$HOME/ai"
BIN_DIR="$AI_DIR/bin"
MODELS_DIR="$AI_DIR/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_CPP_URL="https://github.com/ggml-org/llama.cpp/releases/download/b9672/llama-b9672-bin-ubuntu-vulkan-x64.tar.gz"
LLAMA_SWAP_URL="https://github.com/mostlygeek/llama-swap/releases/download/v226/llama-swap_226_linux_amd64.tar.gz"

mkdir -p "$AI_DIR" "$BIN_DIR" "$MODELS_DIR"

PORT=11435
while ss -ltn | awk '{print $4}' | grep -q ":${PORT}$"; do
  PORT=$((PORT+1))
done
echo "$PORT" > "$AI_DIR/port"

sudo apt-get update
sudo apt-get install -y wget curl jq tar git ca-certificates

cd "$BIN_DIR"

if ! find "$BIN_DIR" -type f -name llama-server ! -path "$BIN_DIR/llama-server" | grep -q .; then
  wget -O llama.cpp.tar.gz "$LLAMA_CPP_URL"
  tar -xzf llama.cpp.tar.gz
fi

LLAMA_SERVER_REAL=$(find "$BIN_DIR" -type f -name llama-server ! -path "$BIN_DIR/llama-server" | head -n1)
LLAMA_DIR=$(dirname "$LLAMA_SERVER_REAL")

cat > "$BIN_DIR/llama-server" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$LLAMA_DIR:\${LD_LIBRARY_PATH:-}"
exec "$LLAMA_DIR/llama-server" "\$@"
EOF
chmod +x "$BIN_DIR/llama-server"

if ! command -v llama-swap >/dev/null 2>&1; then
  cd /tmp
  wget -O llama-swap.tar.gz "$LLAMA_SWAP_URL"
  tar -xzf llama-swap.tar.gz
  sudo install -m755 llama-swap /usr/local/bin/llama-swap
fi

echo "Installed. Put GGUF models into $MODELS_DIR"


echo "Creating LocalAI user service..."

mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/localai.service" <<EOF
[Unit]
Description=LocalAI Server
After=network-online.target

[Service]
ExecStart=%h/ai/start.sh
ExecStop=%h/ai/stop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload || true

install -m755 "$SCRIPT_DIR/start.sh" "$AI_DIR/start.sh"
install -m755 "$SCRIPT_DIR/stop.sh" "$AI_DIR/stop.sh"
install -m755 "$SCRIPT_DIR/rebuild-config.sh" "$AI_DIR/rebuild-config.sh"