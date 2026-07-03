#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=localai.conf
. "$SCRIPT_DIR/localai.conf"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/lib/install.sh"

AI_DIR="${LOCALAI_DIR:-}"
BIN_DIR=""
LIB_DIR=""
CONF_DIR=""
MODELS_DIR=""
LOCALAI_CLI_PATH=""
LOCALAI_CLI_LINK=""
LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-$LOCALAI_DEFAULT_BACKEND}"
LLAMA_CPP_ASSET_RE=""
LLAMA_CPP_URL=""
LLAMA_CPP_JSON=""
LLAMA_SWAP_JSON=""

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [--dir PATH]

Installs LocalAI into the selected directory.

Options:
  --dir PATH     Install LocalAI into PATH. Same as LOCALAI_DIR=PATH.
  -h, --help     Show this help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        [ "$#" -ge 2 ] || fail "missing path after --dir"
        AI_DIR="$2"
        shift 2
        ;;
      --dir=*)
        AI_DIR="${1#--dir=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

select_ai_dir() {
  local answer

  if [ -n "$AI_DIR" ]; then
    AI_DIR="$(expand_path "$AI_DIR")"
    log "Using LocalAI install directory: $AI_DIR"
  elif [ -t 0 ]; then
    printf 'LocalAI install directory [%s]: ' "$LOCALAI_DEFAULT_DIR_DISPLAY"
    read -r answer
  else
    answer=""
    log "No interactive terminal detected. Using default install directory: $LOCALAI_DEFAULT_DIR_DISPLAY"
  fi

  AI_DIR="${AI_DIR:-$(expand_path "${answer:-$LOCALAI_DEFAULT_DIR}")}"
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
    read -r -a packages <<< "$LOCALAI_APT_PACKAGES"
    sudo apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALAI_DNF_PACKAGES"
    sudo dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALAI_YUM_PACKAGES"
    sudo yum install -y "${packages[@]}"
  else
    fail "supported package manager not found. Install required packages listed in localai.conf, then rerun this installer."
  fi
}

resolve_llama_cpp_url() {
  log "Finding llama.cpp $LLAMA_CPP_VERSION asset for backend: $LLAMA_CPP_BACKEND"
  LLAMA_CPP_JSON="$(github_api_get "$LLAMA_CPP_RELEASE_API")"
  LLAMA_CPP_URL="$(release_asset_url "$LLAMA_CPP_JSON" "$LLAMA_CPP_ASSET_RE")"

  [ -n "$LLAMA_CPP_URL" ] || fail "no llama.cpp asset found for backend '$LLAMA_CPP_BACKEND' in release $LLAMA_CPP_VERSION"
}

resolve_llama_swap_release() {
  log "Finding llama-swap $LLAMA_SWAP_VERSION asset"
  LLAMA_SWAP_JSON="$(github_api_get "$LLAMA_SWAP_RELEASE_API")"
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

parse_args "$@"
select_ai_dir
BIN_DIR="$AI_DIR/$LOCALAI_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALAI_LIB_SUBDIR"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
MODELS_DIR="$AI_DIR/$LOCALAI_MODELS_SUBDIR"
LOCALAI_CLI_PATH="$BIN_DIR/$LOCALAI_CLI_NAME"
LOCALAI_CLI_LINK="$LOCALAI_USER_BIN_DIR/$LOCALAI_CLI_NAME"
resolve_llama_swap_paths
select_llama_cpp_asset_regex ""

mkdir -p "$AI_DIR" "$BIN_DIR" "$LIB_DIR" "$CONF_DIR" "$MODELS_DIR"
if [ ! -f "$CONF_DIR/$LOCALAI_PORT_FILE" ] && [ -f "$AI_DIR/$LOCALAI_PORT_FILE" ]; then
  cp "$AI_DIR/$LOCALAI_PORT_FILE" "$CONF_DIR/$LOCALAI_PORT_FILE"
fi

###############################################################################
# INSTALL SYSTEM DEPENDENCIES
###############################################################################

install_system_dependencies
resolve_llama_cpp_url
resolve_llama_swap_release

###############################################################################
# DOWNLOAD RELEASE ARCHIVES
###############################################################################

DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

log "Downloading llama.cpp $LLAMA_CPP_VERSION ($LLAMA_CPP_BACKEND backend)"

download_verified_asset "$LLAMA_CPP_JSON" "$LLAMA_CPP_URL" "$DOWNLOAD_DIR/llama.cpp.tar.gz" "llama.cpp"

log "Downloading llama-swap $LLAMA_SWAP_VERSION"

download_verified_asset "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_URL" "$DOWNLOAD_DIR/llama-swap.tar.gz" "llama-swap"

if [ -x "$BIN_DIR/stop.sh" ] && [ -f "$CONF_DIR/$LOCALAI_PID_FILE" ]; then
  log "Stopping the existing LocalAI service"
  "$BIN_DIR/stop.sh"
elif [ -x "$AI_DIR/stop.sh" ] && { [ -f "$AI_DIR/$LOCALAI_PID_FILE" ] || [ -f "$CONF_DIR/$LOCALAI_PID_FILE" ]; }; then
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
echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
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

install -m755 "$LLAMA_SWAP_REAL" "$LLAMA_SWAP_INSTALL_PATH"

###############################################################################
# SELECT API PORT
###############################################################################

if [ ! -f "$CONF_DIR/$LOCALAI_PORT_FILE" ]; then
  PORT="$LOCALAI_DEFAULT_PORT"
  while ss -ltn | awk '{print $4}' | grep -q ":${PORT}$"; do
    PORT=$((PORT + 1))
  done
  echo "$PORT" > "$CONF_DIR/$LOCALAI_PORT_FILE"
fi

###############################################################################
# INSTALL HELPER SCRIPTS AND SYSTEMD SERVICE
###############################################################################

log "Installing helper scripts and systemd service"

mkdir -p "$LOCALAI_SYSTEMD_USER_DIR"
mkdir -p "$LOCALAI_USER_BIN_DIR"

write_systemd_user_service "$LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME" "$BIN_DIR"

install -m755 "$SCRIPT_DIR/start.sh" "$BIN_DIR/start.sh"
install -m755 "$SCRIPT_DIR/stop.sh" "$BIN_DIR/stop.sh"
install -m755 "$SCRIPT_DIR/rebuild-config.sh" "$BIN_DIR/rebuild-config.sh"
install -m755 "$SCRIPT_DIR/update-local-ai.sh" "$BIN_DIR/update-local-ai.sh"
install -m755 "$SCRIPT_DIR/uninstall-local-ai.sh" "$BIN_DIR/uninstall-local-ai.sh"
install -m755 "$SCRIPT_DIR/localai" "$LOCALAI_CLI_PATH"
install_localai_libs "$SCRIPT_DIR" "$LIB_DIR"
PREVIOUS_LOCALAI_CONF="$CONF_DIR/localai.conf"
if [ -f "$PREVIOUS_LOCALAI_CONF" ]; then
  cp "$PREVIOUS_LOCALAI_CONF" "$DOWNLOAD_DIR/localai.conf.previous"
  PREVIOUS_LOCALAI_CONF="$DOWNLOAD_DIR/localai.conf.previous"
elif [ -f "$AI_DIR/localai.conf" ]; then
  cp "$AI_DIR/localai.conf" "$DOWNLOAD_DIR/localai.conf.previous"
  PREVIOUS_LOCALAI_CONF="$DOWNLOAD_DIR/localai.conf.previous"
fi
install -m644 "$SCRIPT_DIR/localai.conf" "$CONF_DIR/localai.conf"
append_runtime_tuning "$PREVIOUS_LOCALAI_CONF" "installer"

for OLD_HELPER in start.sh stop.sh rebuild-config.sh update-local-ai.sh uninstall-local-ai.sh "$LOCALAI_CLI_NAME"; do
  rm -f -- "$AI_DIR/$OLD_HELPER"
done
for OLD_CONFIG in localai.conf "$LOCALAI_BACKEND_FILE" "$LOCALAI_CONFIG_FILE" "$LOCALAI_PORT_FILE" "$LOCALAI_PID_FILE"; do
  rm -f -- "$AI_DIR/$OLD_CONFIG"
done

ln -sfn "$LOCALAI_CLI_PATH" "$LOCALAI_CLI_LINK"

if ! systemctl --user daemon-reload; then
  echo "Warning: could not reload the systemd user manager." >&2
  echo "You can still use the scripts in $AI_DIR directly." >&2
fi

echo
echo "============================================================"
echo " LocalAI installation completed"
echo "============================================================"
echo
echo "LocalAI commands:"
echo
echo "  Start service:"
echo "    localai start"
echo
echo "  Stop service:"
echo "    localai stop"
echo
echo "  Restart service:"
echo "    localai restart"
echo
echo "  Check status:"
echo "    localai status"
echo
echo "  Check API health:"
echo "    localai check"
echo
echo "  View logs:"
echo "    localai logs"
echo
echo "  List models:"
echo "    localai models"
echo
echo "  Load models:"
echo "    localai load MODEL"
echo "    localai load all"
echo
echo "  Unload models:"
echo "    localai unload MODEL"
echo "    localai unload all"
echo
echo "  Update components:"
echo "    localai update"
echo
echo "  Show versions:"
echo "    localai version"
echo
echo "  Uninstall:"
echo "    localai uninstall"
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
echo "    $BIN_DIR/start.sh"
echo
echo "  Stop manually:"
echo "    $BIN_DIR/stop.sh"
echo
echo "  Rebuild config:"
echo "    $BIN_DIR/rebuild-config.sh"
echo
echo "API endpoint:"
echo "  http://localhost:$(cat "$CONF_DIR/$LOCALAI_PORT_FILE")"
echo
echo "Service file:"
echo "  $LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME"
echo "  ExecStart=$BIN_DIR/start.sh"
echo "  ExecStop=$BIN_DIR/stop.sh"
echo
echo "Models directory:"
echo "  $MODELS_DIR"
echo
echo "CLI command:"
echo "  $LOCALAI_CLI_LINK"
echo
case ":$PATH:" in
  *":$LOCALAI_USER_BIN_DIR:"*) ;;
  *)
    echo "Note: $LOCALAI_USER_BIN_DIR is not in your PATH."
    echo "Add it to your shell profile to run localai from anywhere."
    echo
    ;;
esac
echo "Current versions:"
"$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}'
echo "llama.cpp backend: $LLAMA_CPP_BACKEND"
"$LLAMA_SWAP_BIN" --version 2>&1 | awk 'NR == 1 {print; exit}'
echo
if ! find "$MODELS_DIR" -maxdepth 1 -type f -name '*.gguf' -print -quit | grep -q .; then
  echo "No GGUF models found in:"
  echo "  $MODELS_DIR"
  echo
  echo "LocalAI is installed, but chat requests will not work until you add a model."
  echo "Download or copy a .gguf model into the models directory, then start LocalAI."
  echo
fi
echo "============================================================"
