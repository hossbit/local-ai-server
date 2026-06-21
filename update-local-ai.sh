#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################

# CONFIG

###############################################################################

AI_DIR="$HOME/ai"
BIN_DIR="$AI_DIR/bin"
MODELS_DIR="$AI_DIR/models"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LLAMA_CPP_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
LLAMA_SWAP_API="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"

###############################################################################

# LOGGING

###############################################################################

log() {
echo
echo "================================================================"
echo "[$(date '+%F %T')] $*"
echo "================================================================"
}

fail() {
echo
echo "ERROR: $*" >&2
exit 1
}

###############################################################################

# FETCH RELEASE INFO

###############################################################################

log "Fetching llama.cpp metadata"

LLAMA_CPP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_CPP_API") \
    || fail "Failed to fetch llama.cpp metadata"

log "llama.cpp metadata OK"

log "Fetching llama-swap metadata"

LLAMA_SWAP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_SWAP_API") \
    || fail "Failed to fetch llama-swap metadata"

log "llama-swap metadata OK"

###############################################################################

# PARSE RELEASE INFO

###############################################################################

log "Parsing release information"

LLAMA_CPP_URL=$(echo "$LLAMA_CPP_JSON" | jq -r '.assets[] | select(.name | contains("ubuntu-vulkan-x64")) | .browser_download_url')
LLAMA_SWAP_URL=$(echo "$LLAMA_SWAP_JSON" | jq -r '.assets[] | select(.name | endswith("linux_amd64.tar.gz")) | .browser_download_url')

LATEST_LLAMA_CPP=$(echo "$LLAMA_CPP_JSON" | jq -r '.tag_name' | tr -dc '0-9')
LATEST_LLAMA_SWAP=$(echo "$LLAMA_SWAP_JSON" | jq -r '.tag_name' | tr -dc '0-9')

echo "Latest llama.cpp : $LATEST_LLAMA_CPP"
echo "Latest llama-swap: $LATEST_LLAMA_SWAP"

###############################################################################

# INSTALLED VERSIONS

###############################################################################

CURRENT_LLAMA_CPP=0
CURRENT_LLAMA_SWAP=0

log "Checking installed llama.cpp version"

if [ -x "$BIN_DIR/llama-server" ]; then
CURRENT_LLAMA_CPP=$(
    "$BIN_DIR/llama-server" --version 2>&1 | awk '/version:/ {print $2}'
)

CURRENT_LLAMA_CPP=${CURRENT_LLAMA_CPP:-0}
else
echo "llama-server not found"
fi

log "Checking installed llama-swap version"

if command -v llama-swap >/dev/null 2>&1; then
CURRENT_LLAMA_SWAP=$(timeout 10 llama-swap --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
CURRENT_LLAMA_SWAP=${CURRENT_LLAMA_SWAP:-0}
else
echo "llama-swap not found"
fi

###############################################################################

# REPORT

###############################################################################

echo
echo "================================================================"
echo "Version Report"
echo "================================================================"

printf "%-15s %-12s %-12s %-15s\n" "Component" "Installed" "Latest" "Status"
printf "%-15s %-12s %-12s %-15s\n" "---------" "---------" "------" "------"

CPP_STATUS="OK"
SWAP_STATUS="OK"

[ "$CURRENT_LLAMA_CPP" -lt "$LATEST_LLAMA_CPP" ] && CPP_STATUS="UPDATE"
[ "$CURRENT_LLAMA_SWAP" -lt "$LATEST_LLAMA_SWAP" ] && SWAP_STATUS="UPDATE"

printf "%-15s %-12s %-12s %-15s\n" \
    "llama.cpp" "$CURRENT_LLAMA_CPP" "$LATEST_LLAMA_CPP" "$CPP_STATUS"

printf "%-15s %-12s %-12s %-15s\n" \
    "llama-swap" "$CURRENT_LLAMA_SWAP" "$LATEST_LLAMA_SWAP" "$SWAP_STATUS"

echo "================================================================"

UPDATE_NEEDED=0

[ "$CURRENT_LLAMA_CPP" -lt "$LATEST_LLAMA_CPP" ] && UPDATE_NEEDED=1
[ "$CURRENT_LLAMA_SWAP" -lt "$LATEST_LLAMA_SWAP" ] && UPDATE_NEEDED=1

if [ "$UPDATE_NEEDED" -eq 0 ]; then
log "Everything is already up to date"
exit 0
fi

###############################################################################

# STOP SERVICES

###############################################################################

log "Stopping LocalAI"

"$SCRIPT_DIR/stop.sh"

###############################################################################

# PREPARE DIRECTORIES

###############################################################################

mkdir -p "$AI_DIR" "$BIN_DIR" "$MODELS_DIR"

###############################################################################

# FIND FREE PORT

###############################################################################

PORT=11435

while ss -ltn | awk '{print $4}' | grep -q ":${PORT}$"; do
PORT=$((PORT + 1))
done

echo "$PORT" > "$AI_DIR/port"

echo "Selected port: $PORT"

###############################################################################

# UPDATE LLAMA.CPP

###############################################################################

if [ "$CURRENT_LLAMA_CPP" -lt "$LATEST_LLAMA_CPP" ]; then


log "Updating llama.cpp"

echo "Current: $CURRENT_LLAMA_CPP"
echo "Latest : $LATEST_LLAMA_CPP"

cd "$BIN_DIR"

find "$BIN_DIR" \
    -maxdepth 1 \
    -type d \
    -name "llama-b*-bin-*" \
    -exec rm -rf {} + 2>/dev/null || true

rm -f llama.cpp.tar.gz

wget --show-progress -O llama.cpp.tar.gz "$LLAMA_CPP_URL"

tar -xzf llama.cpp.tar.gz

LLAMA_SERVER_REAL=$(find "$BIN_DIR" -type f -name llama-server ! -path "$BIN_DIR/llama-server" | head -n1)

[ -n "$LLAMA_SERVER_REAL" ] || fail "llama-server not found"

LLAMA_DIR=$(dirname "$LLAMA_SERVER_REAL")

cat > "$BIN_DIR/llama-server" <<WRAPPER
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$LLAMA_DIR:\${LD_LIBRARY_PATH:-}"
exec "$LLAMA_DIR/llama-server" "\$@"
WRAPPER


chmod +x "$BIN_DIR/llama-server"

echo "llama.cpp updated successfully"


fi

###############################################################################

# UPDATE LLAMA-SWAP

###############################################################################

if [ "$CURRENT_LLAMA_SWAP" -lt "$LATEST_LLAMA_SWAP" ]; then


log "Updating llama-swap"

echo "Current: $CURRENT_LLAMA_SWAP"
echo "Latest : $LATEST_LLAMA_SWAP"

cd /tmp

rm -f llama-swap.tar.gz llama-swap

wget --show-progress -O llama-swap.tar.gz "$LLAMA_SWAP_URL"

tar -xzf llama-swap.tar.gz

sudo install -m755 llama-swap /usr/local/bin/llama-swap

echo "llama-swap updated successfully"


fi

###############################################################################

# VERIFY

###############################################################################

log "Installed versions after update"

"$BIN_DIR/llama-server" --version | head -n1

if command -v llama-swap >/dev/null 2>&1; then
timeout 10 llama-swap --version || true
fi

###############################################################################

# START SERVICES

###############################################################################

log "Starting LocalAI"

"$SCRIPT_DIR/start.sh"

###############################################################################

# DONE

###############################################################################

log "Update complete"

echo "Port: $PORT"