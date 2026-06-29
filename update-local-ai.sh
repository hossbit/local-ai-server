#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=localai.conf
. "$SCRIPT_DIR/localai.conf"

AI_DIR=""
BIN_DIR=""
LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-}"
LLAMA_CPP_ASSET_RE=""
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

select_llama_cpp_asset_regex() {
  if [ -z "$LLAMA_CPP_BACKEND" ]; then
    if [ -f "$AI_DIR/$LOCALAI_BACKEND_FILE" ]; then
      LLAMA_CPP_BACKEND="$(<"$AI_DIR/$LOCALAI_BACKEND_FILE")"
    else
      LLAMA_CPP_BACKEND="$LOCALAI_DEFAULT_BACKEND"
    fi
  fi

  case "$LLAMA_CPP_BACKEND" in
    cpu)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_CPU_ASSET_RE"
      ;;
    vulkan)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_VULKAN_ASSET_RE"
      ;;
    rocm)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_ROCM_ASSET_RE"
      ;;
    openvino)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_OPENVINO_ASSET_RE"
      ;;
    sycl-fp16)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_SYCL_FP16_ASSET_RE"
      ;;
    sycl-fp32|sycl)
      LLAMA_CPP_BACKEND="sycl-fp32"
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_SYCL_FP32_ASSET_RE"
      ;;
    *)
      fail "unsupported LLAMA_CPP_BACKEND: $LLAMA_CPP_BACKEND. Use cpu, vulkan, rocm, openvino, sycl-fp16, or sycl-fp32."
      ;;
  esac
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALAI_SERVICE_NAME" >/dev/null 2>&1
}

stop_localai() {
  if has_user_service; then
    log "Stopping LocalAI service"
    systemctl --user stop "$LOCALAI_SERVICE_NAME"
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
  elif [ -x "$AI_DIR/start.sh" ]; then
    log "Starting LocalAI"
    "$AI_DIR/start.sh"
  else
    log "Updated successfully; run the installer to create the service and helper scripts"
  fi
}

print_current_versions() {
  echo
  echo "Current versions:"
  "$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}'
  echo "llama.cpp backend: $LLAMA_CPP_BACKEND"
  llama-swap --version 2>&1 | awk 'NR == 1 {print; exit}'
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

config_assignment_value() {
  local key="$1"
  local file="$2"

  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", value)
      print value
    }
  ' "$file" | tail -n 1
}

append_runtime_tuning() {
  local installed_conf="$AI_DIR/localai.conf"
  local source_conf="$1"
  local key value had_ctx=0 had_gpu=0

  {
    echo
    echo "# Runtime tuning preserved by updater."
    for key in LOCALAI_CTX_SIZE LOCALAI_N_GPU_LAYERS LOCALAI_THREADS LOCALAI_CACHE_TYPE_K LOCALAI_CACHE_TYPE_V LOCALAI_HEALTH_CHECK_TIMEOUT LOCALAI_GLOBAL_TTL; do
      value="$(config_assignment_value "$key" "$source_conf" || true)"
      if [ -n "$value" ]; then
        printf '%s="%s"\n' "$key" "$value"
        [ "$key" = "LOCALAI_CTX_SIZE" ] && had_ctx=1
        [ "$key" = "LOCALAI_N_GPU_LAYERS" ] && had_gpu=1
      fi
    done
    if [ "$LLAMA_CPP_BACKEND" = "cpu" ]; then
      [ "$had_ctx" -eq 1 ] || echo 'LOCALAI_CTX_SIZE="4096"'
      [ "$had_gpu" -eq 1 ] || echo 'LOCALAI_N_GPU_LAYERS="0"'
    fi
  } >> "$installed_conf"
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
select_llama_cpp_asset_regex

###############################################################################
# PREPARE WORKSPACE
###############################################################################

mkdir -p "$AI_DIR" "$BIN_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

###############################################################################
# REFRESH INSTALLED HELPER SCRIPTS
###############################################################################

if [ "$SCRIPT_DIR" != "$AI_DIR" ]; then
  PREVIOUS_LOCALAI_CONF="$AI_DIR/localai.conf"
  if [ -f "$PREVIOUS_LOCALAI_CONF" ]; then
    cp "$PREVIOUS_LOCALAI_CONF" "$TMP_DIR/localai.conf.previous"
    PREVIOUS_LOCALAI_CONF="$TMP_DIR/localai.conf.previous"
  fi
  for SCRIPT in localai start.sh stop.sh rebuild-config.sh update-local-ai.sh uninstall-local-ai.sh; do
    if [ -f "$SCRIPT_DIR/$SCRIPT" ]; then
      install -m755 "$SCRIPT_DIR/$SCRIPT" "$AI_DIR/$SCRIPT"
    fi
  done
  if [ -f "$SCRIPT_DIR/localai.conf" ]; then
    install -m644 "$SCRIPT_DIR/localai.conf" "$AI_DIR/localai.conf"
    append_runtime_tuning "$PREVIOUS_LOCALAI_CONF"
  fi
  if [ -x "$AI_DIR/localai" ]; then
    mkdir -p "$LOCALAI_USER_BIN_DIR"
    cat > "$LOCALAI_USER_BIN_DIR/$LOCALAI_CLI_NAME" <<EOF
#!/usr/bin/env bash
exec "$AI_DIR/localai" "\$@"
EOF
    chmod 755 "$LOCALAI_USER_BIN_DIR/$LOCALAI_CLI_NAME"
  fi
fi

###############################################################################
# FETCH LATEST RELEASE METADATA
###############################################################################

log "Fetching release metadata"
LLAMA_CPP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_CPP_LATEST_API")
LLAMA_SWAP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_SWAP_LATEST_API")

LLAMA_CPP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_CPP_JSON")
LLAMA_SWAP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_SWAP_JSON")
LLAMA_CPP_URL=$(jq -er \
  --arg pattern "$LLAMA_CPP_ASSET_RE" \
  '.assets[] | select(.name | test($pattern)) | .browser_download_url' \
  <<<"$LLAMA_CPP_JSON" | head -n1 || true)
LLAMA_SWAP_URL=$(jq -er \
  --arg pattern "$LLAMA_SWAP_ASSET_RE" \
  '.assets[] | select(.name | test($pattern)) | .browser_download_url' \
  <<<"$LLAMA_SWAP_JSON" | head -n1 || true)

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
  llama-swap --version 2>&1 |
    grep -oE 'v?[0-9]+' |
    head -n1 || true
)
CURRENT_LLAMA_CPP_BACKEND=""
if [ -f "$AI_DIR/$LOCALAI_BACKEND_FILE" ]; then
  CURRENT_LLAMA_CPP_BACKEND="$(<"$AI_DIR/$LOCALAI_BACKEND_FILE")"
fi

printf 'llama.cpp:  installed=%s latest=%s backend=%s\n' "${CURRENT_LLAMA_CPP:-none}" "$LLAMA_CPP_TAG" "$LLAMA_CPP_BACKEND"
printf 'llama-swap: installed=%s latest=%s\n' "${CURRENT_LLAMA_SWAP:-none}" "$LLAMA_SWAP_TAG"

###############################################################################
# DECIDE WHAT NEEDS UPDATING
###############################################################################

NEED_CPP=1
NEED_SWAP=1
if [ -n "$CURRENT_LLAMA_CPP" ]; then
  case "$LLAMA_CPP_TAG" in
    *"$CURRENT_LLAMA_CPP"*) NEED_CPP=0 ;;
  esac
fi
if [ "$CURRENT_LLAMA_CPP_BACKEND" != "$LLAMA_CPP_BACKEND" ]; then
  NEED_CPP=1
fi
if [ -n "$CURRENT_LLAMA_SWAP" ]; then
  case "$LLAMA_SWAP_TAG" in
    *"${CURRENT_LLAMA_SWAP#v}") NEED_SWAP=0 ;;
  esac
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
  curl -4 -fL --retry 3 -o "$TMP_DIR/llama.cpp.tar.gz" "$LLAMA_CPP_URL"
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
  echo "$LLAMA_CPP_BACKEND" > "$AI_DIR/$LOCALAI_BACKEND_FILE"
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
  curl -4 -fL --retry 3 -o "$TMP_DIR/llama-swap.tar.gz" "$LLAMA_SWAP_URL"
  tar -xzf "$TMP_DIR/llama-swap.tar.gz" -C "$TMP_DIR/llama-swap"

  LLAMA_SWAP_REAL=$(find "$TMP_DIR/llama-swap" -type f -name llama-swap | head -n1)
  [ -n "$LLAMA_SWAP_REAL" ] || fail "llama-swap was not found in the downloaded archive"
  sudo install -m755 "$LLAMA_SWAP_REAL" "$LLAMA_SWAP_INSTALL_PATH"
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
