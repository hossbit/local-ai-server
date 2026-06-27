#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_AI_DIR="$HOME/ai"
DEFAULT_AI_DIR_DISPLAY="~/ai"
AI_DIR="${LOCALAI_DIR:-}"
BIN_DIR=""
MODELS_DIR=""
LLAMA_CPP_VERSION="b9672"
LLAMA_SWAP_VERSION="v226"
LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-vulkan}"
LLAMA_CPP_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${LLAMA_CPP_VERSION}"
LLAMA_CPP_ASSET_RE=""
LLAMA_CPP_URL=""
LLAMA_SWAP_URL="https://github.com/mostlygeek/llama-swap/releases/download/v226/llama-swap_226_linux_amd64.tar.gz"

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

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

select_ai_dir() {
  local answer

  if [ -n "$AI_DIR" ]; then
    AI_DIR="$(expand_path "$AI_DIR")"
    log "Using LOCALAI_DIR: $AI_DIR"
  elif [ -t 0 ]; then
    printf 'LocalAI install directory [%s]: ' "$DEFAULT_AI_DIR_DISPLAY"
    read -r answer
  else
    answer=""
    log "No interactive terminal detected. Using default install directory: $DEFAULT_AI_DIR_DISPLAY"
  fi

  AI_DIR="${AI_DIR:-$(expand_path "${answer:-$DEFAULT_AI_DIR}")}"
  case "$AI_DIR" in
    /*) ;;
    *) fail "install directory must be an absolute path or start with ~" ;;
  esac
  case "$AI_DIR" in
    *[[:space:]%]*) fail "install directory cannot contain spaces or percent signs because it is used in a systemd service" ;;
  esac
}

install_system_dependencies() {
  local packages

  log "Installing system dependencies"

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl iproute2 jq tar
  elif command -v dnf >/dev/null 2>&1; then
    packages=(ca-certificates curl iproute jq tar vulkan-loader)
    sudo dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    packages=(ca-certificates curl iproute jq tar vulkan-loader)
    sudo yum install -y "${packages[@]}"
  else
    fail "supported package manager not found. Install ca-certificates, curl, iproute/iproute2, jq, tar, and vulkan-loader, then rerun this installer."
  fi
}

select_llama_cpp_asset_regex() {
  case "$LLAMA_CPP_BACKEND" in
    cpu)
      LLAMA_CPP_ASSET_RE="ubuntu-x64\\.tar\\.gz$"
      ;;
    vulkan)
      LLAMA_CPP_ASSET_RE="ubuntu-vulkan-x64\\.tar\\.gz$"
      ;;
    rocm)
      LLAMA_CPP_ASSET_RE="ubuntu-rocm-x64\\.tar\\.gz$"
      ;;
    openvino)
      LLAMA_CPP_ASSET_RE="ubuntu-openvino-x64\\.tar\\.gz$"
      ;;
    sycl-fp16)
      LLAMA_CPP_ASSET_RE="ubuntu-sycl-fp16-x64\\.tar\\.gz$"
      ;;
    sycl-fp32|sycl)
      LLAMA_CPP_BACKEND="sycl-fp32"
      LLAMA_CPP_ASSET_RE="ubuntu-sycl-fp32-x64\\.tar\\.gz$"
      ;;
    *)
      fail "unsupported LLAMA_CPP_BACKEND: $LLAMA_CPP_BACKEND. Use cpu, vulkan, rocm, openvino, sycl-fp16, or sycl-fp32."
      ;;
  esac
}

resolve_llama_cpp_url() {
  local json

  log "Finding llama.cpp $LLAMA_CPP_VERSION asset for backend: $LLAMA_CPP_BACKEND"
  json=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_CPP_API") ||
    fail "failed to fetch llama.cpp release metadata"
  LLAMA_CPP_URL=$(jq -er \
    --arg pattern "$LLAMA_CPP_ASSET_RE" \
    '.assets[] | select(.name | test($pattern)) | .browser_download_url' \
    <<<"$json" | head -n1 || true)

  [ -n "$LLAMA_CPP_URL" ] || fail "no llama.cpp asset found for backend '$LLAMA_CPP_BACKEND' in release $LLAMA_CPP_VERSION"
}

verify_llama_server() {
  if "$BIN_DIR/llama-server" --version >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
Error: installed llama.cpp backend '$LLAMA_CPP_BACKEND' did not run on this system.

This installer uses upstream llama.cpp Linux x64 release archives. Their file
names include "ubuntu" because that is how upstream publishes them; they can
work on other glibc Linux distributions when runtime libraries are available.

Try another backend, for example:
  LLAMA_CPP_BACKEND=cpu $0
  LLAMA_CPP_BACKEND=vulkan $0

Or install the missing runtime libraries for your selected backend and rerun.
EOF
  exit 1
}

cleanup_bin_artifacts() {
  log "Cleaning old llama.cpp folders and archives"

  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name llama.cpp -exec rm -rf -- {} +
  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' -delete
}

[ "$(uname -m)" = "x86_64" ] || fail "this installer currently supports x86_64 Linux only"

select_ai_dir
BIN_DIR="$AI_DIR/bin"
MODELS_DIR="$AI_DIR/models"
select_llama_cpp_asset_regex

mkdir -p "$AI_DIR" "$BIN_DIR" "$MODELS_DIR"

###############################################################################
# INSTALL SYSTEM DEPENDENCIES
###############################################################################

install_system_dependencies
resolve_llama_cpp_url

###############################################################################
# DOWNLOAD RELEASE ARCHIVES
###############################################################################

DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

log "Downloading llama.cpp $LLAMA_CPP_VERSION ($LLAMA_CPP_BACKEND backend)"

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
echo "$LLAMA_CPP_BACKEND" > "$AI_DIR/llama-cpp-backend"
verify_llama_server
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

cat > "$HOME/.config/systemd/user/localai.service" <<EOF
[Unit]
Description=LocalAI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$AI_DIR/start.sh
ExecStop=$AI_DIR/stop.sh

[Install]
WantedBy=default.target
EOF

install -m755 "$SCRIPT_DIR/start.sh" "$AI_DIR/start.sh"
install -m755 "$SCRIPT_DIR/stop.sh" "$AI_DIR/stop.sh"
install -m755 "$SCRIPT_DIR/rebuild-config.sh" "$AI_DIR/rebuild-config.sh"
install -m755 "$SCRIPT_DIR/update-local-ai.sh" "$AI_DIR/update-local-ai.sh"
install -m755 "$SCRIPT_DIR/uninstall-local-ai.sh" "$AI_DIR/uninstall-local-ai.sh"

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
echo "    $AI_DIR/start.sh"
echo
echo "  Stop manually:"
echo "    $AI_DIR/stop.sh"
echo
echo "  Rebuild config:"
echo "    $AI_DIR/rebuild-config.sh"
echo
echo "  Update components:"
echo "    $AI_DIR/update-local-ai.sh"
echo
echo "  Uninstall:"
echo "    $AI_DIR/uninstall-local-ai.sh"
echo
echo "API endpoint:"
echo "  http://localhost:$(cat "$AI_DIR/port")"
echo
echo "Models directory:"
echo "  $MODELS_DIR"
echo
echo "Current versions:"
"$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}'
echo "llama.cpp backend: $LLAMA_CPP_BACKEND"
llama-swap --version 2>&1 | awk 'NR == 1 {print; exit}'
echo
echo "============================================================"
