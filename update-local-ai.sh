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
source_localai_lib cuda.sh

AI_DIR=""
BIN_DIR=""
LIB_DIR=""
CONF_DIR=""
LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-}"
LLAMA_CPP_ASSET_RE=""
LOCALAI_SOURCE_DIR=""
START_AFTER_UPDATE=1
UPDATE_ALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-start) START_AFTER_UPDATE=0 ;;
    --all) UPDATE_ALL=1 ;;
    *)
      echo "Usage: $0 [--no-start] [--all]" >&2
      exit 2
      ;;
  esac
  shift
done

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

  # Opt-in escape hatch for a local dev checkout (e.g. one with unreleased
  # changes not yet pushed to LOCALAI_REPO_URL): if set, use it instead of
  # fetching from GitHub. Without this, `localai update` always refreshes
  # helper scripts from the public repo and would silently overwrite local
  # changes to lib/*.sh with the upstream version.
  if [ -n "${LOCALAI_LOCAL_SOURCE_DIR:-}" ]; then
    LOCALAI_SOURCE_DIR="$(expand_path "$LOCALAI_LOCAL_SOURCE_DIR")"
    if [ ! -f "$LOCALAI_SOURCE_DIR/install-local-ai.sh" ] || [ ! -f "$LOCALAI_SOURCE_DIR/localai.conf" ]; then
      fail "LOCALAI_LOCAL_SOURCE_DIR=$LOCALAI_SOURCE_DIR does not look like a LocalAI checkout (missing install-local-ai.sh or localai.conf)"
    fi
    log "Using local LocalAI checkout: $LOCALAI_SOURCE_DIR"
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
    if ! localai_version="$(localai_conf_default_version "$CONF_DIR/localai.conf")"; then
      localai_version=""
    fi
    echo "LocalAI: ${localai_version:-$LOCALAI_VERSION}"
  fi
  llama_cpp_display_version "$LLAMA_CPP_BACKEND"
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

  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name llama.cpp ! -name llama.cpp.d -exec rm -rf -- {} +
  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' -delete
}

# update_llama_cpp_backend: brings one backend's own slot
# ($BIN_DIR/llama.cpp.d/<backend>) up to $LLAMA_CPP_TAG if it isn't already,
# leaving every other installed backend untouched. Used both for the normal
# single-backend update (called once for $LLAMA_CPP_BACKEND) and for --all
# (called once per already-installed backend). Sets LLAMA_CPP_BACKEND as a
# side effect (read by verify_llama_server/install_llama_cpp_release_dir/
# activate_llama_cpp_backend), and always leaves the symlink pointing at
# whatever it just installed -- callers doing more than one backend must
# restore the real active one afterward.
update_llama_cpp_backend() {
  local backend="$1"
  local current_version url

  LLAMA_CPP_BACKEND="$backend"
  if [ "$backend" != "cuda" ]; then
    select_llama_cpp_asset_regex ""
    url="$(release_asset_url "$LLAMA_CPP_JSON" "$LLAMA_CPP_ASSET_RE")"
    [ -n "$url" ] || fail "no llama.cpp asset found for backend: $backend"
  fi

  if [ "$backend" = "cuda" ]; then
    current_version="$(cuda_installed_revision)"
  else
    current_version="$(llama_cpp_backend_version "$backend")"
  fi
  printf 'llama.cpp (%s): installed=%s latest=%s\n' "$backend" "${current_version:-none}" "$LLAMA_CPP_TAG"

  if [ -n "$current_version" ] && llama_cpp_versions_match "$LLAMA_CPP_TAG" "$current_version"; then
    return 0
  fi

  log "Installing llama.cpp $LLAMA_CPP_TAG ($backend)"
  if [ "$backend" = "cuda" ]; then
    LLAMA_CPP_VERSION="$LLAMA_CPP_TAG"
    cuda_build_and_install "$TMP_DIR" ||
      fail "CUDA build failed for backend cuda. See the error above."
  else
    mkdir -p "$TMP_DIR/llama.cpp-$backend"
    download_verified_asset "$LLAMA_CPP_JSON" "$url" "$TMP_DIR/llama.cpp-$backend.tar.gz" "llama.cpp ($backend)"
    tar -xzf "$TMP_DIR/llama.cpp-$backend.tar.gz" -C "$TMP_DIR/llama.cpp-$backend" || fail "failed to extract llama.cpp ($backend)"
    install_llama_cpp_release_dir "$TMP_DIR/llama.cpp-$backend" "$TMP_DIR"
  fi
  verify_llama_server
}

refresh_localai_libs() {
  local path rel

  [ -d "$LOCALAI_SOURCE_DIR/lib" ] || return 0
  mkdir -p "$LIB_DIR"
  while IFS= read -r path; do
    rel="${path#"$LOCALAI_SOURCE_DIR/lib/"}"
    mkdir -p "$LIB_DIR/$(dirname "$rel")"
    install -m644 "$path" "$LIB_DIR/$rel"
  done < <(find "$LOCALAI_SOURCE_DIR/lib" -type f | sort)
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
  refresh_localai_libs
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
LLAMA_SWAP_URL="$(release_asset_url "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_ASSET_RE")"

[ -n "$LLAMA_SWAP_URL" ] || fail "no llama-swap Linux amd64 asset found"

###############################################################################
# DECIDE WHICH BACKEND SLOT(S) TO UPDATE
###############################################################################

# The currently-active backend, same value select_llama_cpp_asset_regex
# --detect-installed already resolved above -- restored as active again once
# every requested backend has been brought up to date, since
# update_llama_cpp_backend/install_llama_cpp_release_dir always repoints the
# active symlink at whatever it just installed.
ORIGINAL_BACKEND="$LLAMA_CPP_BACKEND"

BACKENDS_TO_UPDATE=()
if [ "$UPDATE_ALL" -eq 1 ] && [ -d "$BIN_DIR/llama.cpp.d" ] &&
  [ -n "$(find "$BIN_DIR/llama.cpp.d" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
  while IFS= read -r BACKEND_DIR; do
    BACKENDS_TO_UPDATE+=("$(basename "$BACKEND_DIR")")
  done < <(find "$BIN_DIR/llama.cpp.d" -mindepth 1 -maxdepth 1 -type d | sort)
else
  BACKENDS_TO_UPDATE=("$LLAMA_CPP_BACKEND")
fi

###############################################################################
# DETECT INSTALLED VERSIONS
###############################################################################

CURRENT_LLAMA_SWAP=$(
  "$LLAMA_SWAP_BIN" --version 2>&1 |
    grep -oE 'v?[0-9]+' |
    head -n1 || true
)
printf 'llama-swap: installed=%s latest=%s\n' "${CURRENT_LLAMA_SWAP:-none}" "$LLAMA_SWAP_TAG"

NEED_CPP_FOR=()
for BACKEND in "${BACKENDS_TO_UPDATE[@]}"; do
  if [ "$BACKEND" = "cuda" ]; then
    CURRENT_VERSION="$(cuda_installed_revision)"
  else
    CURRENT_VERSION="$(llama_cpp_backend_version "$BACKEND")"
  fi
  printf 'llama.cpp (%s): installed=%s latest=%s\n' "$BACKEND" "${CURRENT_VERSION:-none}" "$LLAMA_CPP_TAG"
  if [ -z "$CURRENT_VERSION" ] || ! llama_cpp_versions_match "$LLAMA_CPP_TAG" "$CURRENT_VERSION"; then
    NEED_CPP_FOR+=("$BACKEND")
  fi
done

###############################################################################
# DECIDE WHAT NEEDS UPDATING
###############################################################################

NEED_SWAP=1
if [ -n "$CURRENT_LLAMA_SWAP" ]; then
  if [ "${LLAMA_SWAP_TAG#v}" = "${CURRENT_LLAMA_SWAP#v}" ]; then
    NEED_SWAP=0
  fi
fi

if ((${#NEED_CPP_FOR[@]} == 0 && NEED_SWAP == 0)); then
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
# UPDATE LLAMA.CPP BACKEND(S)
###############################################################################

for BACKEND in "${NEED_CPP_FOR[@]}"; do
  update_llama_cpp_backend "$BACKEND"
done

LLAMA_CPP_BACKEND="$ORIGINAL_BACKEND"
activate_llama_cpp_backend

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
