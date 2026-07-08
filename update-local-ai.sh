#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localai.conf"
elif [ -f "$SCRIPT_DIR/localai.conf" ]; then
  # shellcheck source=localai.conf
  . "$SCRIPT_DIR/localai.conf"
else
  echo "Error: localai.conf not found." >&2
  exit 1
fi
source_localai_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: common.sh" >&2
  exit 1
}
source_localai_common
source_localai_lib install.sh

AI_DIR=""
BIN_DIR=""
LIB_DIR=""
CONF_DIR=""
LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-}"
LLAMA_CPP_ASSET_RE=""
LOCALAI_SOURCE_DIR=""
START_AFTER_UPDATE=1

if [ "${1:-}" = "--no-start" ]; then
  START_AFTER_UPDATE=0
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--no-start]" >&2
  exit 2
fi

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

localai_archive_url() {
  case "${LOCALAI_REF:-main}" in
    v*|refs/tags/*)
      printf '%s/refs/tags/%s.tar.gz\n' "${LOCALAI_TARBALL_BASE:-https://github.com/hossbit/local-ai-server/archive}" "${LOCALAI_REF#refs/tags/}"
      ;;
    refs/heads/*)
      printf '%s/%s.tar.gz\n' "${LOCALAI_TARBALL_BASE:-https://github.com/hossbit/local-ai-server/archive}" "$LOCALAI_REF"
      ;;
    *)
      printf '%s/refs/heads/%s.tar.gz\n' "${LOCALAI_TARBALL_BASE:-https://github.com/hossbit/local-ai-server/archive}" "${LOCALAI_REF:-main}"
      ;;
  esac
}

resolve_localai_source_dir() {
  local archive_file extracted

  if [ -f "$SCRIPT_DIR/install-local-ai.sh" ] && [ -f "$SCRIPT_DIR/localai.conf" ]; then
    LOCALAI_SOURCE_DIR="$SCRIPT_DIR"
    return
  fi

  log "Fetching LocalAI helper scripts"
  LOCALAI_SOURCE_DIR="$TMP_DIR/localai-source"

  if have git; then
    git clone --depth 1 --branch "${LOCALAI_REF:-main}" \
      "${LOCALAI_REPO_URL:-https://github.com/hossbit/local-ai-server.git}" \
      "$LOCALAI_SOURCE_DIR"
  else
    archive_file="$TMP_DIR/localai.tar.gz"
    curl -4 -fsSL "$(localai_archive_url)" -o "$archive_file"
    tar -xzf "$archive_file" -C "$TMP_DIR"
    extracted="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'local-ai-server-*' | head -n 1)"
    [ -n "$extracted" ] || fail "could not find extracted LocalAI source directory"
    mv "$extracted" "$LOCALAI_SOURCE_DIR"
  fi

  [ -f "$LOCALAI_SOURCE_DIR/localai.conf" ] || fail "downloaded LocalAI source is missing localai.conf"
  [ -x "$LOCALAI_SOURCE_DIR/localai" ] || fail "downloaded LocalAI source is missing localai"
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALAI_SERVICE_NAME" >/dev/null 2>&1
}

stop_localai() {
  if has_user_service; then
    log "Stopping LocalAI service"
    systemctl --user stop "$LOCALAI_SERVICE_NAME"
  elif [ -x "$BIN_DIR/stop.sh" ]; then
    log "Stopping LocalAI"
    "$BIN_DIR/stop.sh"
  elif [ -x "$AI_DIR/stop.sh" ]; then
    log "Stopping LocalAI"
    "$AI_DIR/stop.sh"
  elif [ -x "$SCRIPT_DIR/stop.sh" ]; then
    log "Stopping LocalAI"
    "$SCRIPT_DIR/stop.sh"
  fi
}

start_localai() {
  if has_user_service; then
    log "Starting LocalAI service"
    systemctl --user start "$LOCALAI_SERVICE_NAME"
  elif [ -x "$BIN_DIR/start.sh" ]; then
    log "Starting LocalAI"
    "$BIN_DIR/start.sh"
  elif [ -x "$AI_DIR/start.sh" ]; then
    log "Starting LocalAI"
    "$AI_DIR/start.sh"
  else
    log "Updated successfully; run the installer to create the service and helper scripts"
  fi
}

print_current_versions() {
  local localai_version

  echo
  echo "Current versions:"
  if [ -f "$CONF_DIR/localai.conf" ]; then
    localai_version="$(localai_conf_default_version "$CONF_DIR/localai.conf" || true)"
    echo "LocalAI: ${localai_version:-$LOCALAI_VERSION}"
  fi
  "$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}'
  echo "llama.cpp backend: $LLAMA_CPP_BACKEND"
  "$LLAMA_SWAP_BIN" --version 2>&1 | awk 'NR == 1 {print; exit}'
}

verify_llama_server() {
  if "$BIN_DIR/llama-server" --version >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
Error: installed llama.cpp backend '$LLAMA_CPP_BACKEND' did not run on this system.

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

###############################################################################
# CHECK REQUIREMENTS
###############################################################################

for COMMAND in curl jq tar; do
  command -v "$COMMAND" >/dev/null 2>&1 || fail "required command not found: $COMMAND"
done

[ "$(uname -m)" = "x86_64" ] || fail "this updater currently supports x86_64 Linux only"

AI_DIR="$(resolve_ai_dir)"
BIN_DIR="$AI_DIR/$LOCALAI_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALAI_LIB_SUBDIR"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
resolve_llama_swap_paths
select_llama_cpp_asset_regex --detect-installed

###############################################################################
# PREPARE WORKSPACE
###############################################################################

mkdir -p "$AI_DIR" "$BIN_DIR" "$LIB_DIR" "$CONF_DIR"
if [ ! -f "$CONF_DIR/$LOCALAI_PORT_FILE" ] && [ -f "$AI_DIR/$LOCALAI_PORT_FILE" ]; then
  cp "$AI_DIR/$LOCALAI_PORT_FILE" "$CONF_DIR/$LOCALAI_PORT_FILE"
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
resolve_localai_source_dir

###############################################################################
# REFRESH INSTALLED HELPER SCRIPTS
###############################################################################

if [ "$LOCALAI_SOURCE_DIR" != "$AI_DIR" ]; then
  PREVIOUS_LOCALAI_CONF="$CONF_DIR/localai.conf"
  if [ -f "$PREVIOUS_LOCALAI_CONF" ]; then
    cp "$PREVIOUS_LOCALAI_CONF" "$TMP_DIR/localai.conf.previous"
    PREVIOUS_LOCALAI_CONF="$TMP_DIR/localai.conf.previous"
  elif [ -f "$AI_DIR/localai.conf" ]; then
    cp "$AI_DIR/localai.conf" "$TMP_DIR/localai.conf.previous"
    PREVIOUS_LOCALAI_CONF="$TMP_DIR/localai.conf.previous"
  fi
  for SCRIPT in localai start.sh stop.sh rebuild-config.sh update-local-ai.sh uninstall-local-ai.sh; do
    if [ -f "$LOCALAI_SOURCE_DIR/$SCRIPT" ]; then
      install -m755 "$LOCALAI_SOURCE_DIR/$SCRIPT" "$BIN_DIR/$SCRIPT"
    fi
  done
  if [ -f "$LOCALAI_SOURCE_DIR/localai.conf" ]; then
    install -m644 "$LOCALAI_SOURCE_DIR/localai.conf" "$CONF_DIR/localai.conf"
    append_runtime_tuning "$PREVIOUS_LOCALAI_CONF" "updater"
  fi
  if [ -f "$LOCALAI_SOURCE_DIR/lib/common.sh" ] && [ -f "$LOCALAI_SOURCE_DIR/lib/install.sh" ]; then
    install_localai_libs "$LOCALAI_SOURCE_DIR" "$LIB_DIR"
  fi
  if [ -x "$BIN_DIR/localai" ]; then
    mkdir -p "$LOCALAI_USER_BIN_DIR"
    ln -sfn "$BIN_DIR/localai" "$LOCALAI_USER_BIN_DIR/$LOCALAI_CLI_NAME"
  fi
  mkdir -p "$LOCALAI_SYSTEMD_USER_DIR"
  write_systemd_user_service "$LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME" "$BIN_DIR"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  for OLD_HELPER in start.sh stop.sh rebuild-config.sh update-local-ai.sh uninstall-local-ai.sh "$LOCALAI_CLI_NAME"; do
    rm -f -- "$AI_DIR/$OLD_HELPER"
  done
  for OLD_CONFIG in localai.conf "$LOCALAI_BACKEND_FILE" "$LOCALAI_CONFIG_FILE" "$LOCALAI_PORT_FILE" "$LOCALAI_PID_FILE"; do
    rm -f -- "$AI_DIR/$OLD_CONFIG"
  done
fi

###############################################################################
# FETCH LATEST RELEASE METADATA
###############################################################################

log "Fetching release metadata"
LLAMA_CPP_JSON="$(github_api_get "$LLAMA_CPP_LATEST_API")"
LLAMA_SWAP_JSON="$(github_api_get "$LLAMA_SWAP_LATEST_API")"

LLAMA_CPP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_CPP_JSON")
LLAMA_SWAP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_SWAP_JSON")
LLAMA_CPP_URL="$(release_asset_url "$LLAMA_CPP_JSON" "$LLAMA_CPP_ASSET_RE")"
LLAMA_SWAP_URL="$(release_asset_url "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_ASSET_RE")"

[ -n "$LLAMA_CPP_URL" ] || fail "no llama.cpp asset found for backend: $LLAMA_CPP_BACKEND"
[ -n "$LLAMA_SWAP_URL" ] || fail "no llama-swap Linux amd64 asset found"

###############################################################################
# DETECT INSTALLED VERSIONS
###############################################################################

CURRENT_LLAMA_CPP=$(
  "$BIN_DIR/llama-server" --version 2>&1 |
    awk '/version:/ {print $2; exit}' || true
)
CURRENT_LLAMA_SWAP=$(
  "$LLAMA_SWAP_BIN" --version 2>&1 |
    grep -oE 'v?[0-9]+' |
    head -n1 || true
)
CURRENT_LLAMA_CPP_BACKEND=""
if [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ]; then
  CURRENT_LLAMA_CPP_BACKEND="$(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"
fi

printf 'llama.cpp:  installed=%s latest=%s backend=%s\n' "${CURRENT_LLAMA_CPP:-none}" "$LLAMA_CPP_TAG" "$LLAMA_CPP_BACKEND"
printf 'llama-swap: installed=%s latest=%s\n' "${CURRENT_LLAMA_SWAP:-none}" "$LLAMA_SWAP_TAG"

###############################################################################
# DECIDE WHAT NEEDS UPDATING
###############################################################################

NEED_CPP=1
NEED_SWAP=1
if [ -n "$CURRENT_LLAMA_CPP" ]; then
  if llama_cpp_versions_match "$LLAMA_CPP_TAG" "$CURRENT_LLAMA_CPP"; then
    NEED_CPP=0
  fi
fi
if [ "$CURRENT_LLAMA_CPP_BACKEND" != "$LLAMA_CPP_BACKEND" ]; then
  NEED_CPP=1
fi
if [ -n "$CURRENT_LLAMA_SWAP" ]; then
  if [ "${LLAMA_SWAP_TAG#v}" = "${CURRENT_LLAMA_SWAP#v}" ]; then
    NEED_SWAP=0
  fi
fi

if ((NEED_CPP == 0 && NEED_SWAP == 0)); then
  log "Everything is already up to date"
  cleanup_bin_artifacts
  print_current_versions
  exit 0
fi

###############################################################################
# STOP RUNNING SERVICE
###############################################################################

stop_localai

###############################################################################
# INSTALL LLAMA.CPP
###############################################################################

if ((NEED_CPP)); then
  log "Installing llama.cpp $LLAMA_CPP_TAG"
  mkdir -p "$TMP_DIR/llama.cpp"
  download_verified_asset "$LLAMA_CPP_JSON" "$LLAMA_CPP_URL" "$TMP_DIR/llama.cpp.tar.gz" "llama.cpp"
  tar -xzf "$TMP_DIR/llama.cpp.tar.gz" -C "$TMP_DIR/llama.cpp"

  LLAMA_SERVER_REAL=$(find "$TMP_DIR/llama.cpp" -type f -name llama-server | head -n1)
  [ -n "$LLAMA_SERVER_REAL" ] || fail "llama-server was not found in the downloaded archive"
  LLAMA_DIR=$(dirname "$LLAMA_SERVER_REAL")

  rm -rf "$BIN_DIR/llama.cpp"
  mv "$LLAMA_DIR" "$BIN_DIR/llama.cpp"

  cat > "$TMP_DIR/llama-server" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$BIN_DIR/llama.cpp:\${LD_LIBRARY_PATH:-}"
exec "$BIN_DIR/llama.cpp/llama-server" "\$@"
EOF
  install -m755 "$TMP_DIR/llama-server" "$BIN_DIR/llama-server"
  echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  verify_llama_server
fi

###############################################################################
# CLEAN OLD LLAMA.CPP FOLDERS AND ARCHIVES
###############################################################################

cleanup_bin_artifacts

###############################################################################
# INSTALL LLAMA-SWAP
###############################################################################

if ((NEED_SWAP)); then
  log "Installing llama-swap $LLAMA_SWAP_TAG"
  mkdir -p "$TMP_DIR/llama-swap"
  download_verified_asset "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_URL" "$TMP_DIR/llama-swap.tar.gz" "llama-swap"
  tar -xzf "$TMP_DIR/llama-swap.tar.gz" -C "$TMP_DIR/llama-swap"

  LLAMA_SWAP_REAL=$(find "$TMP_DIR/llama-swap" -type f -name llama-swap | head -n1)
  [ -n "$LLAMA_SWAP_REAL" ] || fail "llama-swap was not found in the downloaded archive"
  install -m755 "$LLAMA_SWAP_REAL" "$LLAMA_SWAP_INSTALL_PATH"
fi

###############################################################################
# RESTART SERVICE
###############################################################################

if [ "$START_AFTER_UPDATE" -eq 1 ]; then
  start_localai
else
  log "Service left stopped (--no-start)"
fi

log "LocalAI update completed"
print_current_versions
