#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bootstrap.sh" 2>/dev/null ||
  . "$SCRIPT_DIR/../lib/bootstrap.sh" 2>/dev/null ||
  { echo "Error: missing LocalAI bootstrap library: lib/bootstrap.sh" >&2; exit 1; }
source_localai_lib install.sh
source_localai_lib cuda.sh

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
  local sudo_cmd=()

  log "Installing system dependencies"

  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to install system dependencies when not running as root"
    sudo_cmd=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    "${sudo_cmd[@]}" apt-get update
    read -r -a packages <<< "$LOCALAI_APT_PACKAGES"
    [ "$LLAMA_CPP_BACKEND" = "cuda" ] && read -r -a packages <<< "$LOCALAI_APT_PACKAGES $LOCALAI_CUDA_APT_PACKAGES"
    "${sudo_cmd[@]}" apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALAI_DNF_PACKAGES"
    [ "$LLAMA_CPP_BACKEND" = "cuda" ] && read -r -a packages <<< "$LOCALAI_DNF_PACKAGES $LOCALAI_CUDA_DNF_PACKAGES"
    "${sudo_cmd[@]}" dnf install -y "${packages[@]}" ||
      fail "failed to install dnf packages. On RHEL 7/8, enable EPEL if jq is unavailable in the enabled repositories."
  elif command -v yum >/dev/null 2>&1; then
    read -r -a packages <<< "$LOCALAI_YUM_PACKAGES"
    [ "$LLAMA_CPP_BACKEND" = "cuda" ] && read -r -a packages <<< "$LOCALAI_YUM_PACKAGES $LOCALAI_CUDA_YUM_PACKAGES"
    "${sudo_cmd[@]}" yum install -y "${packages[@]}" ||
      fail "failed to install yum packages. On RHEL 7/8, enable EPEL if jq is unavailable in the enabled repositories."
  else
    fail "supported package manager not found. Install required packages listed in localai.conf, then rerun this installer."
  fi
}

resolve_llama_cpp_url() {
  local release_api

  log "Finding llama.cpp $LLAMA_CPP_VERSION asset for backend: $LLAMA_CPP_BACKEND"
  if [ "$LLAMA_CPP_VERSION" = "latest" ]; then
    LLAMA_CPP_JSON="$(resolve_llama_cpp_latest_json)"
    LLAMA_CPP_VERSION="$(jq -er '.tag_name' <<<"$LLAMA_CPP_JSON")"
  else
    release_api="$(release_api_for_version "$LLAMA_CPP_VERSION" "$LLAMA_CPP_RELEASE_API" "$LLAMA_CPP_LATEST_API")"
    LLAMA_CPP_JSON="$(github_api_get "$release_api")"
  fi

  # cuda has no prebuilt release asset -- it's a source build pinned to this
  # same resolved $LLAMA_CPP_VERSION tag (a real git tag either way, stable
  # or bleeding-edge), so cuda and the other backends never silently drift to
  # different llama.cpp revisions.
  [ "$LLAMA_CPP_BACKEND" = "cuda" ] && return 0

  # A stable vX.Y.Z release carries no binaries of its own -- resolve to the
  # bleeding-edge release its assets actually live in.
  LLAMA_CPP_BINARY_JSON="$(resolve_llama_cpp_binary_json "$LLAMA_CPP_JSON")"
  LLAMA_CPP_URL="$(release_asset_url "$LLAMA_CPP_BINARY_JSON" "$LLAMA_CPP_ASSET_RE")"

  [ -n "$LLAMA_CPP_URL" ] || fail "no llama.cpp asset found for backend '$LLAMA_CPP_BACKEND' in release $LLAMA_CPP_VERSION"
}

resolve_llama_swap_release() {
  local release_api

  log "Finding llama-swap $LLAMA_SWAP_VERSION asset"
  if [ "$LLAMA_SWAP_VERSION" = "latest" ]; then
    LLAMA_SWAP_JSON="$(github_api_get "$LLAMA_SWAP_LATEST_API")"
    LLAMA_SWAP_VERSION="$(jq -er '.tag_name' <<<"$LLAMA_SWAP_JSON")"
  else
    release_api="$(release_api_for_version "$LLAMA_SWAP_VERSION" "$LLAMA_SWAP_RELEASE_API" "$LLAMA_SWAP_LATEST_API")"
    LLAMA_SWAP_JSON="$(github_api_get "$release_api")"
  fi
  LLAMA_SWAP_URL="${LLAMA_SWAP_URL:-$(release_asset_url "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_ASSET_RE")}"

  [ -n "$LLAMA_SWAP_URL" ] || fail "no llama-swap Linux amd64 asset found in release $LLAMA_SWAP_VERSION"
}

explain_llama_server_failure() {
  local hint
  hint="$(backend_dependency_hint "$LLAMA_CPP_BACKEND" 2>/dev/null)" ||
    hint="Fix:
  Install the missing runtime libraries for your selected backend and rerun."

  cat >&2 <<EOF
Error: installed llama.cpp backend '$LLAMA_CPP_BACKEND' did not run on this system.

This installer uses upstream llama.cpp Linux x64 release archives. Their file
names include "ubuntu" because that is how upstream publishes them; they can
work on other glibc Linux distributions when runtime libraries are available.

$hint

Or, try another backend:
  LLAMA_CPP_BACKEND=cpu $0
  LLAMA_CPP_BACKEND=vulkan $0
  LLAMA_CPP_BACKEND=auto $0
EOF
}

install_llama_cpp_archive() {
  local archive="$1"

  rm -rf "$DOWNLOAD_DIR/llama.cpp"
  mkdir -p "$DOWNLOAD_DIR/llama.cpp"
  tar -xzf "$archive" \
    -C "$DOWNLOAD_DIR/llama.cpp" \
    || fail "failed to extract llama.cpp"

  install_llama_cpp_release_dir "$DOWNLOAD_DIR/llama.cpp" "$DOWNLOAD_DIR"
}

fallback_to_cpu_backend() {
  local failed_backend="$LLAMA_CPP_BACKEND"

  # An explicit cuda request must fail rather than silently substitute CPU
  # (matching cuda_resolve_explicit_backend and the updater). Only `auto`,
  # which chose cuda on its own, or an explicit LOCALAI_CUDA_FALLBACK=1 may
  # fall back here.
  if [ "$failed_backend" = "cuda" ] &&
    [ "${ORIGINAL_LLAMA_CPP_BACKEND:-}" != "auto" ] &&
    [ "${LOCALAI_CUDA_FALLBACK:-0}" != "1" ]; then
    explain_llama_server_failure
    exit 1
  fi

  if [ "$LOCALAI_CPU_FALLBACK" != "1" ] || [ "$LLAMA_CPP_BACKEND" = "cpu" ]; then
    explain_llama_server_failure
    exit 1
  fi

  echo "Warning: llama.cpp backend '$failed_backend' did not run; retrying with CPU backend." >&2
  LLAMA_CPP_BACKEND="cpu"
  select_llama_cpp_asset_regex ""
  resolve_llama_cpp_url

  log "Downloading llama.cpp $LLAMA_CPP_VERSION (cpu fallback backend)"
  download_verified_asset "$LLAMA_CPP_BINARY_JSON" "$LLAMA_CPP_URL" "$DOWNLOAD_DIR/llama.cpp.cpu.tar.gz" "llama.cpp cpu fallback"

  log "Installing llama.cpp CPU fallback"
  install_llama_cpp_archive "$DOWNLOAD_DIR/llama.cpp.cpu.tar.gz"
  if ! llama_server_runs; then
    explain_llama_server_failure
    exit 1
  fi
}

cleanup_bin_artifacts() {
  log "Cleaning old llama.cpp folders and archives"

  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name llama.cpp ! -name llama.cpp.d -exec rm -rf -- {} +
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
ORIGINAL_LLAMA_CPP_BACKEND="$LLAMA_CPP_BACKEND"
select_llama_cpp_asset_regex ""

mkdir -p "$AI_DIR" "$BIN_DIR" "$LIB_DIR" "$CONF_DIR" "$MODELS_DIR" "$CONF_DIR/$LOCALAI_MODELS_OVERRIDE_SUBDIR" "$CONF_DIR/$LOCALAI_KEYS_SUBDIR"
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
SERVICE_WAS_RUNNING=0
INSTALL_COMPLETE=0
cleanup_install() {
  local status=$?

  trap - EXIT
  [ -z "${DOWNLOAD_DIR:-}" ] || rm -rf -- "$DOWNLOAD_DIR"
  if [ "${SERVICE_WAS_RUNNING:-0}" -eq 1 ] && [ "${INSTALL_COMPLETE:-0}" -eq 0 ]; then
    echo "Install failed; restarting the previous LocalAI service..." >&2
    if has_user_service; then
      systemctl --user start "$LOCALAI_SERVICE_NAME" || true
    elif [ -x "$BIN_DIR/start.sh" ]; then
      "$BIN_DIR/start.sh" || true
    fi
  fi
  exit "$status"
}
trap cleanup_install EXIT

if [ "$LLAMA_CPP_BACKEND" != "cuda" ]; then
  log "Downloading llama.cpp $LLAMA_CPP_VERSION ($LLAMA_CPP_BACKEND backend)"
  download_verified_asset "$LLAMA_CPP_BINARY_JSON" "$LLAMA_CPP_URL" "$DOWNLOAD_DIR/llama.cpp.tar.gz" "llama.cpp"
fi

log "Downloading llama-swap $LLAMA_SWAP_VERSION"

download_verified_asset "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_URL" "$DOWNLOAD_DIR/llama-swap.tar.gz" "llama-swap"

if pid_file_matches_process "$CONF_DIR/$LOCALAI_PID_FILE" "$CONF_DIR/$LOCALAI_PID_FILE.start"; then
  SERVICE_WAS_RUNNING=1
elif [ -f "$AI_DIR/$LOCALAI_PID_FILE" ] &&
  pid_file_matches_process "$AI_DIR/$LOCALAI_PID_FILE" "$AI_DIR/$LOCALAI_PID_FILE.start"; then
  SERVICE_WAS_RUNNING=1
elif has_user_service && systemctl --user is-active --quiet "$LOCALAI_SERVICE_NAME"; then
  SERVICE_WAS_RUNNING=1
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if [ -x "$BIN_DIR/stop.sh" ]; then
    log "Stopping the existing LocalAI service"
    "$BIN_DIR/stop.sh"
  elif [ -x "$AI_DIR/stop.sh" ]; then
    log "Stopping the existing LocalAI service"
    "$AI_DIR/stop.sh"
  fi
fi

###############################################################################
# INSTALL LLAMA.CPP
###############################################################################

log "Installing llama.cpp"

if [ "$LLAMA_CPP_BACKEND" = "cuda" ]; then
  cuda_build_and_install "$DOWNLOAD_DIR" || fallback_to_cpu_backend
else
  install_llama_cpp_archive "$DOWNLOAD_DIR/llama.cpp.tar.gz"
  if ! llama_server_runs; then
    fallback_to_cpu_backend
  fi
fi
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
  while port_is_listening "$PORT"; do
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

write_systemd_user_service "$LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME" "$BIN_DIR" "$CONF_DIR/$LOCALAI_PID_FILE"

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

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  log "Starting LocalAI service"
  if has_user_service; then
    systemctl --user start "$LOCALAI_SERVICE_NAME"
  elif [ -x "$BIN_DIR/start.sh" ]; then
    "$BIN_DIR/start.sh"
  fi
fi
INSTALL_COMPLETE=1

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
echo "Current versions:"
llama_cpp_display_version "$LLAMA_CPP_BACKEND"
echo "llama.cpp backend: $LLAMA_CPP_BACKEND"
"$LLAMA_SWAP_BIN" --version 2>&1 | awk 'NR == 1 {print; exit}'
echo
if ! localai_has_model_entries "$MODELS_DIR"; then
  echo "No GGUF models found in:"
  echo "  $MODELS_DIR"
  echo
  echo "LocalAI is installed, but chat requests will not work until you add a model."
  echo "Download or copy a .gguf model into the models directory, then start LocalAI."
  echo
fi
echo "============================================================"
ENSURE_PATH_STATUS=0
ensure_cli_on_path || ENSURE_PATH_STATUS=$?
reconnect_shell_on_path "$ENSURE_PATH_STATUS"
