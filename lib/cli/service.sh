# shellcheck shell=bash disable=SC2154

service_cmd() {
  local action="$1"

  if has_user_service; then
    print_service_details "systemd user service"
    echo "Running: systemctl --user $action $SERVICE_UNIT"
    systemctl --user "$action" "$SERVICE_UNIT"
    echo "LocalAI service $action completed."
    return
  fi

  case "$action" in
    start)
      [ -x "$BIN_DIR/start.sh" ] || fail "missing helper: $BIN_DIR/start.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/start.sh"
      "$BIN_DIR/start.sh"
      ;;
    stop)
      [ -x "$BIN_DIR/stop.sh" ] || fail "missing helper: $BIN_DIR/stop.sh"
      print_service_details "helper script"
      echo "Running: $BIN_DIR/stop.sh"
      "$BIN_DIR/stop.sh"
      ;;
    restart)
      service_cmd stop
      service_cmd start
      ;;
    *)
      fail "unsupported service action: $action"
      ;;
  esac
}

status_cmd() {
  if has_user_service; then
    print_service_details "systemd user service"
    echo "Systemd service:"
    systemctl --user status "$SERVICE_UNIT" --no-pager || true
    echo
    echo "Note: this service uses a helper script and may show active (exited); the process check below is authoritative."
  else
    print_service_details "helper script"
  fi
  pid_status
}

check_cmd() {
  local port model candidate models_json chat=0

  if [ "${1:-}" = "--chat" ]; then
    chat=1
  elif [ "$#" -gt 0 ]; then
    fail "usage: localai check [--chat]"
  fi

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALAI_DEFAULT_PORT")"
  pid_status
  localai_model_entries "$MODELS_DIR" >/dev/null

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    fail "curl and jq are required for API checks"
  fi

  echo
  echo "API models:"
  if ! models_json="$(curl --max-time 10 -fsS "http://${LOCALAI_LISTEN_HOST}:${port}/v1/models")"; then
    fail "API did not respond at http://${LOCALAI_LISTEN_HOST}:${port}/v1/models"
  fi
  jq -r '.data[]?.id' <<<"$models_json"

  if [ "$chat" -eq 1 ]; then
    while IFS= read -r candidate; do
      if [ -z "$candidate" ] || [ "$candidate" = "null" ]; then
        continue
      fi
      if ! model_is_embedding_name "$candidate"; then
        model="$candidate"
        break
      fi
    done < <(jq -r '.data[]?.id' <<<"$models_json")
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      fail "no model is available for chat check"
    fi
    echo
    echo "Chat check:"
    curl --max-time 120 -fsS "http://${LOCALAI_LISTEN_HOST}:${port}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}],\"max_tokens\":8}" |
      jq -r '.choices[0].message.content // .choices[0].text // .'
  fi
}

logs_cmd() {
  if has_user_service; then
    journalctl --user -u "$SERVICE_UNIT" -f
    return
  fi

  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  tail -f "$LOG_FILE"
}
