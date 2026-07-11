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
  local base model candidate models_json chat_response chat=0

  if [ "${1:-}" = "--chat" ]; then
    chat=1
  elif [ "$#" -gt 0 ]; then
    fail "usage: localai check [--chat]"
  fi

  pid_status
  localai_model_entries "$MODELS_DIR" >/dev/null

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    fail "curl and jq are required for API checks"
  fi

  base="$(api_base_url)"

  echo
  echo "API models:"
  if ! models_json="$(curl --max-time 10 -fsS "$base/v1/models")"; then
    fail "API did not respond at $base/v1/models"
  fi
  jq -r '.data[]?.id' <<<"$models_json"

  if [ "$chat" -eq 1 ]; then
    model=""
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
    echo "Chat check ($model):"
    if ! chat_response="$(curl --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, messages: [{role: "user", content: "Reply with OK"}], max_tokens: 8, stream: false}')")"; then
      fail "chat completion failed for $model at $base/v1/chat/completions"
    fi
    jq -r '.choices[0].message.content // .choices[0].text // .' <<<"$chat_response"
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
