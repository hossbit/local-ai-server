# shellcheck shell=bash disable=SC2154

reload_model_ids() {
  local file="$1"

  [ -f "$file" ] || return 0
  sed -n 's/^  "\(.*\)":$/\1/p' "$file" | LC_ALL=C sort
}

reload_report_model_diff() {
  local old_file="$1" new_file="$2"
  local old_ids new_ids added removed

  old_ids="$(reload_model_ids "$old_file")"
  new_ids="$(reload_model_ids "$new_file")"

  # LC_ALL=C keeps comm's ordering check consistent with the LC_ALL=C sort
  # above; locale-aware collation (e.g. en_US.UTF-8) can order mixed-case
  # model names in a way comm's own locale-aware check then rejects as
  # "not in sorted order".
  added="$(LC_ALL=C comm -13 <(grep -v '^$' <<<"$old_ids") <(grep -v '^$' <<<"$new_ids"))"
  removed="$(LC_ALL=C comm -23 <(grep -v '^$' <<<"$old_ids") <(grep -v '^$' <<<"$new_ids"))"

  if [ -n "$added" ]; then
    echo "  Added:"
    while IFS= read -r model; do
      [ -n "$model" ] && echo "    + $model"
    done <<<"$added"
  fi
  if [ -n "$removed" ]; then
    echo "  Removed:"
    while IFS= read -r model; do
      [ -n "$model" ] && echo "    - $model"
    done <<<"$removed"
  fi
}

reload_cmd() {
  local rebuild candidate candidate_keys config_same=0 keys_same=0

  [ "$#" -eq 0 ] || fail "usage: localai reload"

  rebuild="$BIN_DIR/rebuild-config.sh"
  [ -x "$rebuild" ] || fail "missing helper: $rebuild"

  candidate="$(mktemp "${TMPDIR:-/tmp}/localai-reload.XXXXXX")"
  candidate_keys="$(mktemp "${TMPDIR:-/tmp}/localai-reload-keys.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$candidate' '$candidate_keys'" EXIT

  "$rebuild" "$candidate" "$candidate_keys" >/dev/null

  [ -f "$CONFIG" ] && diff -q "$CONFIG" "$candidate" >/dev/null 2>&1 && config_same=1
  if [ -f "$KEYS_FILE" ] || [ -f "$candidate_keys" ]; then
    [ -f "$KEYS_FILE" ] && [ -f "$candidate_keys" ] &&
      diff -q "$KEYS_FILE" "$candidate_keys" >/dev/null 2>&1 && keys_same=1
  else
    keys_same=1
  fi

  if [ "$config_same" -eq 1 ] && [ "$keys_same" -eq 1 ]; then
    echo "No model changes detected in $MODELS_DIR; config.yaml is already up to date."
    echo "LocalAI was not restarted."
    return 0
  fi

  echo "Model changes detected:"
  reload_report_model_diff "$CONFIG" "$candidate"
  echo
  service_cmd restart
}

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
