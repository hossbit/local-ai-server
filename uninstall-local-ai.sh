#!/usr/bin/env bash
set -Eeuo pipefail

AI_DIR="$HOME/ai"
BIN_DIR="$AI_DIR/bin"
MODELS_DIR="$AI_DIR/models"
SERVICE_NAME="localai.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
REMOVE_MODELS=0
REMOVE_LLAMA_SWAP=0
FORCE=0

usage() {
  cat <<EOF
Usage: $0 [--remove-models] [--remove-llama-swap] [--force]

Uninstalls the LocalAI service and helper files created by install-local-ai.sh.

Options:
  --remove-models       Also delete $MODELS_DIR
  --remove-llama-swap   Also delete /usr/local/bin/llama-swap
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
  has_systemctl_user && systemctl --user cat "$SERVICE_NAME" >/dev/null 2>&1
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remove-models) REMOVE_MODELS=1 ;;
    --remove-llama-swap) REMOVE_LLAMA_SWAP=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

cat <<EOF
This will uninstall LocalAI for the current user.

Will remove:
  $SERVICE_FILE
  $BIN_DIR
  $AI_DIR/start.sh
  $AI_DIR/stop.sh
  $AI_DIR/rebuild-config.sh
  $AI_DIR/update-local-ai.sh
  $AI_DIR/uninstall-local-ai.sh
  $AI_DIR/config.yaml
  $AI_DIR/port
  $AI_DIR/logs
  $AI_DIR/llama-swap.pid

Will keep:
  $MODELS_DIR

EOF

if [ "$REMOVE_MODELS" -eq 1 ]; then
  echo "Will also remove:"
  echo "  $MODELS_DIR"
  echo
fi

if [ "$REMOVE_LLAMA_SWAP" -eq 1 ]; then
  echo "Will also remove:"
  echo "  /usr/local/bin/llama-swap"
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
  systemctl --user stop "$SERVICE_NAME" || warn "could not stop $SERVICE_NAME"
  systemctl --user disable "$SERVICE_NAME" || warn "could not disable $SERVICE_NAME"
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
  systemctl --user reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

###############################################################################
# REMOVE LOCALAI FILES
###############################################################################

log "Removing LocalAI files"

remove_if_exists "$BIN_DIR"
remove_if_exists "$AI_DIR/start.sh"
remove_if_exists "$AI_DIR/stop.sh"
remove_if_exists "$AI_DIR/rebuild-config.sh"
remove_if_exists "$AI_DIR/update-local-ai.sh"
remove_if_exists "$AI_DIR/uninstall-local-ai.sh"
remove_if_exists "$AI_DIR/config.yaml"
remove_if_exists "$AI_DIR/port"
remove_if_exists "$AI_DIR/logs"
remove_if_exists "$AI_DIR/llama-swap.pid"

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
  if [ -e /usr/local/bin/llama-swap ] || [ -L /usr/local/bin/llama-swap ]; then
    log "Removing /usr/local/bin/llama-swap"
    sudo rm -f -- /usr/local/bin/llama-swap
  fi
fi

echo
echo "LocalAI uninstall completed."
if [ -d "$MODELS_DIR" ]; then
  echo "Models were kept in $MODELS_DIR"
fi
