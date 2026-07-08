update_cmd() {
  local updater="$BIN_DIR/update-local-ai.sh"
  [ -x "$updater" ] || updater="$SCRIPT_DIR/update-local-ai.sh"
  [ -x "$updater" ] || fail "missing updater: $BIN_DIR/update-local-ai.sh"
  "$updater" "$@"
}

version_cmd() {
  echo "LocalAI: $LOCALAI_VERSION"
  echo "Install directory: $AI_DIR"

  if [ -x "$BIN_DIR/llama-server" ]; then
    "$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print "llama.cpp: " $0; exit}'
  else
    echo "llama.cpp: not installed"
  fi

  if [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ]; then
    echo "llama.cpp backend: $(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"
  fi

  if [ -x "$LLAMA_SWAP_BIN" ]; then
    "$LLAMA_SWAP_BIN" --version 2>&1 | awk 'NR == 1 {print "llama-swap: " $0; exit}'
  else
    echo "llama-swap: not installed"
  fi
}

uninstall_cmd() {
  local uninstaller="$BIN_DIR/uninstall-local-ai.sh"
  [ -x "$uninstaller" ] || uninstaller="$SCRIPT_DIR/uninstall-local-ai.sh"
  [ -x "$uninstaller" ] || fail "missing uninstaller: $BIN_DIR/uninstall-local-ai.sh"
  "$uninstaller" "$@"
}
