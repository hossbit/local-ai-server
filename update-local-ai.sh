#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bootstrap.sh" 2>/dev/null ||
  . "$SCRIPT_DIR/../lib/bootstrap.sh" 2>/dev/null ||
  { echo "Error: missing LocalAI bootstrap library: lib/bootstrap.sh" >&2; exit 1; }
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
UPDATE_COMPLETE=0
SERVICE_STOPPED=0
SERVICE_STARTED=0
CHECK_ONLY=0
SNAPSHOT_ACTIVE=0
PENDING_SNAPSHOT=""
# Captured before anything resolves "latest" to a concrete tag, so the
# installation manifest records the policy, not just the result.
LLAMA_CPP_POLICY="${LLAMA_CPP_VERSION:-latest}"
LLAMA_SWAP_POLICY="${LLAMA_SWAP_VERSION:-latest}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-start) START_AFTER_UPDATE=0 ;;
    --all) UPDATE_ALL=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--check] [--no-start] [--all]

Installs the newest llama.cpp build for the active backend and the newest
llama-swap, then restarts LocalAI. If the restarted service does not become
ready, the previous versions are restored automatically.

  --check     Only report installed and latest versions; change nothing
  --no-start  Leave LocalAI stopped after updating
  --all       Update every installed backend, not just the active one
EOF
      exit 0
      ;;
    *)
      echo "Usage: $0 [--check] [--no-start] [--all]" >&2
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

# cleanup_update: always remove the temporary workspace, and if a failure
# exits after the running service was stopped, bring the previous install
# back up instead of leaving LocalAI down.
#
# When components were already replaced, swap the pending snapshot back in
# first, so the restarted service runs the versions that worked before
# rather than the ones that just failed.
cleanup_update() {
  local status=$?

  trap - EXIT
  [ -z "${TMP_DIR:-}" ] || rm -rf -- "$TMP_DIR"
  if [ "$UPDATE_COMPLETE" -eq 0 ] && [ "$SNAPSHOT_ACTIVE" -eq 1 ]; then
    if [ "$SERVICE_STARTED" -eq 1 ]; then
      stop_localai >/dev/null 2>&1 || true
    fi
    if localai_snapshot_has_content "$PENDING_SNAPSHOT"; then
      echo "Update failed; restoring the previous llama.cpp / llama-swap versions..." >&2
      if localai_snapshot_swap "$PENDING_SNAPSHOT"; then
        rm -rf -- "$PENDING_SNAPSHOT"
        echo "Previous versions restored." >&2
      else
        echo "Warning: some components could not be restored automatically." >&2
        echo "The pre-update files are kept in $PENDING_SNAPSHOT; run 'localai rollback' to retry." >&2
      fi
    else
      rm -rf -- "$PENDING_SNAPSHOT"
    fi
    # --all repoints the active backend while it works; put back the one
    # that was active before the update.
    if [ -n "${ORIGINAL_BACKEND:-}" ] && [ -d "$BIN_DIR/llama.cpp.d/$ORIGINAL_BACKEND" ]; then
      LLAMA_CPP_BACKEND="$ORIGINAL_BACKEND"
      activate_llama_cpp_backend || true
    fi
  fi
  if [ "$SERVICE_STOPPED" -eq 1 ] && [ "$START_AFTER_UPDATE" -eq 1 ] && [ "$UPDATE_COMPLETE" -eq 0 ]; then
    echo "Restarting the previous LocalAI service..." >&2
    start_localai || echo "Warning: LocalAI did not restart. Check: localai logs" >&2
  fi
  exit "$status"
}

# finish_snapshot: after a successful update, keep the replaced components
# as the rollback point (or discard them when LOCALAI_KEEP_PREVIOUS=0).
finish_snapshot() {
  local previous

  [ "$SNAPSHOT_ACTIVE" -eq 1 ] || return 0
  previous="$(localai_previous_dir)"
  if [ "${LOCALAI_KEEP_PREVIOUS:-1}" = "1" ] && localai_snapshot_has_content "$PENDING_SNAPSHOT"; then
    rm -rf -- "$previous"
    mv -- "$PENDING_SNAPSHOT" "$previous"
    echo "Previous versions kept for 'localai rollback' in $previous"
  else
    rm -rf -- "$PENDING_SNAPSHOT"
  fi
  SNAPSHOT_ACTIVE=0
}

# recover_interrupted_update: a pending snapshot left behind means an
# earlier update was killed before it could finish or roll back (power loss,
# SIGKILL). Every component swap is atomic, so restoring the snapshot returns
# to the exact pre-update state instead of a guessed mix.
recover_interrupted_update() {
  local pending

  pending="$(localai_previous_dir).pending"
  [ -d "$pending" ] || return 0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "Warning: an earlier update did not finish; run 'localai update' to recover it." >&2
    return 0
  fi
  log "Recovering from an interrupted update"
  if localai_snapshot_has_content "$pending"; then
    localai_snapshot_swap "$pending" ||
      fail "could not restore the components saved in $pending. Inspect it, or run 'localai rollback'."
  fi
  rm -rf -- "$pending"
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

cleanup_bin_artifacts() {
  log "Cleaning old llama.cpp folders and archives"

  find "$BIN_DIR" -mindepth 1 -maxdepth 1 -type d ! -name llama.cpp ! -name llama.cpp.d ! -name "${LOCALAI_PREVIOUS_SUBDIR:-previous}" ! -name "${LOCALAI_PREVIOUS_SUBDIR:-previous}.pending" -exec rm -rf -- {} +
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
  local current_version url compare_tag

  LLAMA_CPP_BACKEND="$backend"
  if [ "$backend" != "cuda" ]; then
    select_llama_cpp_asset_regex ""
    url="$(release_asset_url "$LLAMA_CPP_BINARY_JSON" "$LLAMA_CPP_ASSET_RE")"
    [ -n "$url" ] || fail "no llama.cpp asset found for backend: $backend"
  fi

  if [ "$backend" = "cuda" ]; then
    current_version="$(cuda_installed_revision)"
    compare_tag="$LLAMA_CPP_TAG"
  else
    current_version="$(llama_cpp_backend_version "$backend")"
    compare_tag="$LLAMA_CPP_BINARY_TAG"
  fi

  if [ -n "$current_version" ] && llama_cpp_versions_match "$compare_tag" "$current_version"; then
    return 0
  fi

  log "Installing llama.cpp $compare_tag ($backend)"
  if [ "$backend" = "cuda" ]; then
    LLAMA_CPP_VERSION="$LLAMA_CPP_TAG"
    cuda_build_and_install "$TMP_DIR" ||
      fail "CUDA build failed for backend cuda. See the error above."
  else
    mkdir -p "$TMP_DIR/llama.cpp-$backend"
    download_verified_asset "$LLAMA_CPP_BINARY_JSON" "$url" "$TMP_DIR/llama.cpp-$backend.tar.gz" "llama.cpp ($backend)"
    tar -xzf "$TMP_DIR/llama.cpp-$backend.tar.gz" -C "$TMP_DIR/llama.cpp-$backend" || fail "failed to extract llama.cpp ($backend)"
    install_llama_cpp_release_dir "$TMP_DIR/llama.cpp-$backend" "$TMP_DIR"
  fi
  verify_llama_server || exit 1
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
  # Remove the retired custom workspace, preserving other user files.
  rm -f -- "$LIB_DIR/ui.html" "$CONF_DIR/ui/index.html"
  rmdir -- "$CONF_DIR/ui" 2>/dev/null || true
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
trap cleanup_update EXIT
# Saved before update_llama_cpp_backend changes it per backend, so the
# manifest can name the active backend's release asset.
ACTIVE_ASSET_RE="$LLAMA_CPP_ASSET_RE"
recover_interrupted_update
if [ "$CHECK_ONLY" -eq 0 ]; then
  resolve_localai_source_dir
else
  # --check changes nothing, so it skips the helper-script refresh below.
  LOCALAI_SOURCE_DIR="$AI_DIR"
fi

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
  write_systemd_user_service "$LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME" "$BIN_DIR" "$CONF_DIR/$LOCALAI_PID_FILE"
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
if [ "${LLAMA_CPP_VERSION:-latest}" = "latest" ]; then
  LLAMA_CPP_JSON="$(resolve_llama_cpp_latest_json)"
else
  log "Using pinned llama.cpp version $LLAMA_CPP_VERSION"
  LLAMA_CPP_JSON="$(github_api_get "$(release_api_for_version "$LLAMA_CPP_VERSION" "$LLAMA_CPP_RELEASE_API" "$LLAMA_CPP_LATEST_API")")"
fi

if [ "${LLAMA_SWAP_VERSION:-latest}" = "latest" ]; then
  LLAMA_SWAP_JSON="$(github_api_get "$LLAMA_SWAP_LATEST_API")"
else
  log "Using pinned llama-swap version $LLAMA_SWAP_VERSION"
  LLAMA_SWAP_JSON="$(github_api_get "$(release_api_for_version "$LLAMA_SWAP_VERSION" "$LLAMA_SWAP_RELEASE_API" "$LLAMA_SWAP_LATEST_API")")"
fi

LLAMA_CPP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_CPP_JSON")
LLAMA_SWAP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_SWAP_JSON")

# A stable vX.Y.Z release carries no binaries of its own -- resolve to the
# bleeding-edge release its assets actually live in. Used for every non-cuda
# backend below; cuda builds from source and checks out $LLAMA_CPP_TAG
# directly regardless of channel.
LLAMA_CPP_BINARY_JSON="$(resolve_llama_cpp_binary_json "$LLAMA_CPP_JSON")"
LLAMA_CPP_BINARY_TAG=$(jq -er '.tag_name' <<<"$LLAMA_CPP_BINARY_JSON")
LLAMA_SWAP_URL="${LLAMA_SWAP_URL:-$(release_asset_url "$LLAMA_SWAP_JSON" "$LLAMA_SWAP_ASSET_RE")}"

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

CURRENT_LLAMA_SWAP="$(llama_swap_version "$LLAMA_SWAP_BIN")"
printf 'llama-swap: installed=%s latest=%s\n' "${CURRENT_LLAMA_SWAP:-none}" "$LLAMA_SWAP_TAG"

NEED_CPP_FOR=()
for BACKEND in "${BACKENDS_TO_UPDATE[@]}"; do
  if [ "$BACKEND" = "cuda" ]; then
    CURRENT_VERSION="$(cuda_installed_revision)"
    COMPARE_TAG="$LLAMA_CPP_TAG"
  else
    CURRENT_VERSION="$(llama_cpp_backend_version "$BACKEND")"
    COMPARE_TAG="$LLAMA_CPP_BINARY_TAG"
  fi
  printf 'llama.cpp (%s): installed=%s latest=%s\n' "$BACKEND" "${CURRENT_VERSION:-none}" "$COMPARE_TAG"
  if [ -z "$CURRENT_VERSION" ] || ! llama_cpp_versions_match "$COMPARE_TAG" "$CURRENT_VERSION"; then
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

# write_update_manifest: record what is now installed for the active backend.
write_update_manifest() {
  local release url="" digest=""

  if [ "$ORIGINAL_BACKEND" = "cuda" ]; then
    release="$LLAMA_CPP_TAG"
  else
    release="$LLAMA_CPP_BINARY_TAG"
    if [ -n "$ACTIVE_ASSET_RE" ]; then
      url="$(release_asset_url "$LLAMA_CPP_BINARY_JSON" "$ACTIVE_ASSET_RE")"
      [ -z "$url" ] || digest="$(release_asset_digest "$LLAMA_CPP_BINARY_JSON" "$url")"
    fi
  fi
  localai_write_manifest "$LLAMA_CPP_POLICY" "$release" "$url" "$digest" \
    "$LLAMA_SWAP_POLICY" "$LLAMA_SWAP_TAG" "$LLAMA_SWAP_URL" ||
    echo "Warning: could not write $CONF_DIR/$LOCALAI_MANIFEST_FILE" >&2
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  if ((${#NEED_CPP_FOR[@]} == 0 && NEED_SWAP == 0)); then
    echo "LocalAI is up to date. Nothing was changed."
  else
    echo "Updates available:"
    for BACKEND in "${NEED_CPP_FOR[@]}"; do
      echo "  llama.cpp ($BACKEND)"
    done
    ((NEED_SWAP == 0)) || echo "  llama-swap"
    echo "Nothing was changed. Run 'localai update' to install them."
  fi
  exit 0
fi

if ((${#NEED_CPP_FOR[@]} == 0 && NEED_SWAP == 0)); then
  log "Everything is already up to date"
  cleanup_bin_artifacts
  [ -f "$CONF_DIR/$LOCALAI_MANIFEST_FILE" ] || write_update_manifest
  print_current_versions
  exit 0
fi

###############################################################################
# START THE UPDATE SNAPSHOT
###############################################################################

# Everything this update replaces is recorded here first, so any later
# failure can put the previous versions back (see cleanup_update).
PENDING_SNAPSHOT="$(localai_previous_dir).pending"
localai_snapshot_begin "$PENDING_SNAPSHOT" ||
  fail "could not create the update snapshot in $PENDING_SNAPSHOT; nothing was changed"
# shellcheck disable=SC2034 # Read by install_llama_cpp_release_dir (lib/install.sh).
LOCALAI_PREVIOUS_DIR="$PENDING_SNAPSHOT"
SNAPSHOT_ACTIVE=1

###############################################################################
# STOP RUNNING SERVICE
###############################################################################

SERVICE_WAS_RUNNING=0
if pid_file_matches_process "$CONF_DIR/$LOCALAI_PID_FILE" "$CONF_DIR/$LOCALAI_PID_FILE.start"; then
  SERVICE_WAS_RUNNING=1
elif has_user_service && systemctl --user is-active --quiet "$LOCALAI_SERVICE_NAME"; then
  SERVICE_WAS_RUNNING=1
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  SERVICE_STOPPED=1
  stop_localai
fi

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
  chmod +x "$LLAMA_SWAP_REAL"
  [ -n "$(llama_swap_version "$LLAMA_SWAP_REAL")" ] ||
    fail "the downloaded llama-swap $LLAMA_SWAP_TAG did not run on this system"
  localai_snapshot_add_file "$PENDING_SNAPSHOT" llama-swap "$LLAMA_SWAP_INSTALL_PATH" ||
    fail "could not save the current llama-swap before replacing it"
  install -m755 "$LLAMA_SWAP_REAL" "$LLAMA_SWAP_INSTALL_PATH.new"
  mv -f -- "$LLAMA_SWAP_INSTALL_PATH.new" "$LLAMA_SWAP_INSTALL_PATH"
fi

###############################################################################
# RESTART SERVICE
###############################################################################

# start.sh (run directly or by the systemd unit) only returns success once
# llama-swap answers on its API, so a failure here means the new versions do
# not work on this system; cleanup_update then restores the previous ones.
if [ "$START_AFTER_UPDATE" -eq 1 ]; then
  SERVICE_STARTED=1
  if ! start_localai; then
    echo "Error: LocalAI did not become ready with the updated components." >&2
    exit 1
  fi
else
  log "Service left stopped (--no-start)"
fi

UPDATE_COMPLETE=1
finish_snapshot
write_update_manifest

log "LocalAI update completed"
print_current_versions
