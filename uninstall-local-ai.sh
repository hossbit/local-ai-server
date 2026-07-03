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

AI_DIR=""
BIN_DIR=""
LIB_DIR=""
CONF_DIR=""
MODELS_DIR=""
SERVICE_FILE="$LOCALAI_SYSTEMD_USER_DIR/$LOCALAI_SERVICE_NAME"
LOCALAI_CLI_LINK="$LOCALAI_USER_BIN_DIR/$LOCALAI_CLI_NAME"
REMOVE_MODELS=0
REMOVE_LLAMA_SWAP=0
FORCE=0

usage() {
  local usage_ai_dir usage_bin_dir llama_swap_path

  usage_ai_dir="$(resolve_ai_dir)"
  usage_bin_dir="$usage_ai_dir/$LOCALAI_BIN_SUBDIR"
  llama_swap_path="${LLAMA_SWAP_INSTALL_PATH:-$usage_bin_dir/llama-swap}"

  cat <<EOF
Usage: $0 [--dir PATH] [--remove-models] [--remove-llama-swap] [--force]

Uninstalls the LocalAI service and helper files created by install-local-ai.sh.

Options:
  --dir PATH           Uninstall LocalAI from PATH. Same as LOCALAI_DIR=PATH.
  --remove-models       Also delete the models directory.
  --remove-llama-swap   Also delete $llama_swap_path
  --force               Do not prompt before deleting files
  -h, --help            Show this help
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  echo "Warning: $*" >&2
}

has_systemctl_user() {
  command -v systemctl >/dev/null 2>&1
}

has_user_service() {
  has_systemctl_user && systemctl --user cat "$LOCALAI_SERVICE_NAME" >/dev/null 2>&1
}

confirm() {
  [ "$FORCE" -eq 1 ] && return 0

  printf '%s [y/N] ' "$1"
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

remove_if_exists() {
  local TARGET=$1

  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    rm -rf -- "$TARGET"
  fi
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

target_is_removed_by_parent() {
  local target="$1"
  local remove_target

  for remove_target in "${REMOVE_TARGETS[@]}"; do
    case "$target" in
      "$remove_target"|"$remove_target"/*) return 0 ;;
    esac
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      # shellcheck disable=SC2034
      LOCALAI_DIR="$2"
      shift 2
      ;;
    --dir=*)
      # shellcheck disable=SC2034
      LOCALAI_DIR="${1#--dir=}"
      shift
      ;;
    --remove-models)
      REMOVE_MODELS=1
      shift
      ;;
    --remove-llama-swap)
      REMOVE_LLAMA_SWAP=1
      shift
      ;;
    --force)
      FORCE=1
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

AI_DIR="$(resolve_ai_dir)"
BIN_DIR="$AI_DIR/$LOCALAI_BIN_SUBDIR"
LIB_DIR="$AI_DIR/$LOCALAI_LIB_SUBDIR"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
MODELS_DIR="$AI_DIR/$LOCALAI_MODELS_SUBDIR"
resolve_llama_swap_paths

REMOVE_TARGETS=()
KEEP_TARGETS=()
EXTRA_REMOVE_TARGETS=()
HAS_USER_SERVICE=0

if has_user_service; then
  HAS_USER_SERVICE=1
fi

for TARGET in \
  "$SERVICE_FILE" \
  "$BIN_DIR" \
  "$LIB_DIR" \
  "$CONF_DIR" \
  "$AI_DIR/start.sh" \
  "$AI_DIR/stop.sh" \
  "$AI_DIR/rebuild-config.sh" \
  "$AI_DIR/update-local-ai.sh" \
  "$AI_DIR/uninstall-local-ai.sh" \
  "$AI_DIR/$LOCALAI_CLI_NAME" \
  "$AI_DIR/localai.conf" \
  "$AI_DIR/$LOCALAI_BACKEND_FILE" \
  "$AI_DIR/$LOCALAI_CONFIG_FILE" \
  "$AI_DIR/$LOCALAI_PORT_FILE" \
  "$AI_DIR/$LOCALAI_LOGS_SUBDIR" \
  "$AI_DIR/$LOCALAI_PID_FILE"
do
  if path_exists "$TARGET"; then
    REMOVE_TARGETS+=("$TARGET")
  fi
done

if path_exists "$LOCALAI_CLI_LINK"; then
  REMOVE_TARGETS+=("$LOCALAI_CLI_LINK")
fi

if [ "$REMOVE_MODELS" -eq 1 ]; then
  if path_exists "$MODELS_DIR"; then
    EXTRA_REMOVE_TARGETS+=("$MODELS_DIR")
  fi
elif path_exists "$MODELS_DIR"; then
  KEEP_TARGETS+=("$MODELS_DIR")
fi

if [ "$REMOVE_LLAMA_SWAP" -eq 1 ]; then
  if path_exists "$LLAMA_SWAP_INSTALL_PATH" && ! target_is_removed_by_parent "$LLAMA_SWAP_INSTALL_PATH"; then
    EXTRA_REMOVE_TARGETS+=("$LLAMA_SWAP_INSTALL_PATH")
  fi
elif path_exists "$LLAMA_SWAP_INSTALL_PATH" && ! target_is_removed_by_parent "$LLAMA_SWAP_INSTALL_PATH"; then
  KEEP_TARGETS+=("$LLAMA_SWAP_INSTALL_PATH")
fi

if [ "$HAS_USER_SERVICE" -eq 0 ] && [ "${#REMOVE_TARGETS[@]}" -eq 0 ] && [ "${#EXTRA_REMOVE_TARGETS[@]}" -eq 0 ]; then
  echo "LocalAI is already uninstalled for the current user."
  if [ "${#KEEP_TARGETS[@]}" -gt 0 ]; then
    echo
    echo "Kept:"
    for TARGET in "${KEEP_TARGETS[@]}"; do
      echo "  $TARGET"
    done
  fi
  exit 0
fi

echo "This will uninstall LocalAI for the current user."
echo "Resolved LocalAI directory: $AI_DIR"
echo

if [ "$HAS_USER_SERVICE" -eq 1 ] || [ "${#REMOVE_TARGETS[@]}" -gt 0 ]; then
  echo "Will remove:"
  if [ "$HAS_USER_SERVICE" -eq 1 ]; then
    echo "  systemd user service $LOCALAI_SERVICE_NAME"
  fi
  for TARGET in "${REMOVE_TARGETS[@]}"; do
    echo "  $TARGET"
  done
  echo
fi

if [ "${#KEEP_TARGETS[@]}" -gt 0 ]; then
  echo "Will keep:"
  for TARGET in "${KEEP_TARGETS[@]}"; do
    echo "  $TARGET"
  done
  echo
fi

if [ "${#EXTRA_REMOVE_TARGETS[@]}" -gt 0 ]; then
  if [ "$HAS_USER_SERVICE" -eq 1 ] || [ "${#REMOVE_TARGETS[@]}" -gt 0 ]; then
    echo "Will also remove:"
  else
    echo "Will remove:"
  fi
  for TARGET in "${EXTRA_REMOVE_TARGETS[@]}"; do
    echo "  $TARGET"
  done
  echo
fi

if ! confirm "Continue?"; then
  echo "Uninstall cancelled."
  exit 0
fi

###############################################################################
# STOP AND REMOVE USER SERVICE
###############################################################################

if has_user_service; then
  log "Stopping and disabling systemd user service"
  systemctl --user stop "$LOCALAI_SERVICE_NAME" || warn "could not stop $LOCALAI_SERVICE_NAME"
  systemctl --user disable "$LOCALAI_SERVICE_NAME" || warn "could not disable $LOCALAI_SERVICE_NAME"
elif [ -x "$BIN_DIR/stop.sh" ]; then
  log "Stopping LocalAI with helper script"
  "$BIN_DIR/stop.sh" || warn "could not stop LocalAI with $BIN_DIR/stop.sh"
elif [ -x "$AI_DIR/stop.sh" ]; then
  log "Stopping LocalAI with helper script"
  "$AI_DIR/stop.sh" || warn "could not stop LocalAI with $AI_DIR/stop.sh"
fi

if [ -f "$SERVICE_FILE" ]; then
  log "Removing systemd user service file"
  rm -f -- "$SERVICE_FILE"
fi

if has_systemctl_user; then
  systemctl --user daemon-reload || warn "could not reload the systemd user manager"
  systemctl --user reset-failed "$LOCALAI_SERVICE_NAME" >/dev/null 2>&1 || true
fi

###############################################################################
# REMOVE LOCALAI FILES
###############################################################################

log "Removing LocalAI files"

remove_if_exists "$BIN_DIR"
remove_if_exists "$LIB_DIR"
remove_if_exists "$CONF_DIR"
remove_if_exists "$AI_DIR/start.sh"
remove_if_exists "$AI_DIR/stop.sh"
remove_if_exists "$AI_DIR/rebuild-config.sh"
remove_if_exists "$AI_DIR/update-local-ai.sh"
remove_if_exists "$AI_DIR/uninstall-local-ai.sh"
remove_if_exists "$AI_DIR/$LOCALAI_CLI_NAME"
remove_if_exists "$LOCALAI_CLI_LINK"
remove_if_exists "$AI_DIR/localai.conf"
remove_if_exists "$AI_DIR/$LOCALAI_BACKEND_FILE"
remove_if_exists "$AI_DIR/$LOCALAI_CONFIG_FILE"
remove_if_exists "$AI_DIR/$LOCALAI_PORT_FILE"
remove_if_exists "$AI_DIR/$LOCALAI_LOGS_SUBDIR"
remove_if_exists "$AI_DIR/$LOCALAI_PID_FILE"

if [ "$REMOVE_MODELS" -eq 1 ]; then
  remove_if_exists "$MODELS_DIR"
fi

if [ -d "$AI_DIR" ] && [ -z "$(find "$AI_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  rmdir "$AI_DIR"
fi

###############################################################################
# OPTIONAL GLOBAL LLAMA-SWAP REMOVAL
###############################################################################

if [ "$REMOVE_LLAMA_SWAP" -eq 1 ]; then
  if [ -e "$LLAMA_SWAP_INSTALL_PATH" ] || [ -L "$LLAMA_SWAP_INSTALL_PATH" ]; then
    log "Removing $LLAMA_SWAP_INSTALL_PATH"
    rm -f -- "$LLAMA_SWAP_INSTALL_PATH"
  fi
fi

echo
echo "LocalAI uninstall completed."
if [ -d "$MODELS_DIR" ]; then
  echo "Models were kept in $MODELS_DIR"
fi
