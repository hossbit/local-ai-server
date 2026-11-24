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

# user_lingers: true when systemd keeps this user's services running without
# a login session (loginctl enable-linger). Without it a user service stops at
# logout and never starts at boot, which matters on headless/SSH servers.
user_lingers() {
  [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = "yes" ] ||
    [ -e "/var/lib/systemd/linger/$(id -un)" ]
}

autostart_state() {
  local enabled=no linger=no
  systemctl --user is-enabled --quiet "$SERVICE_UNIT" 2>/dev/null && enabled=yes
  user_lingers && linger=yes
  printf '%s %s\n' "$enabled" "$linger"
}

autostart_cmd() {
  local action="${1:-status}" enabled linger user
  [ "$#" -le 1 ] || fail "usage: localai autostart [on|off|status]"
  has_user_service || fail "autostart needs the LocalAI systemd user service; it was not found."
  user="$(id -un)"

  case "$action" in
    on)
      systemctl --user enable "$SERVICE_UNIT" >/dev/null ||
        fail "could not enable $SERVICE_UNIT"
      if ! user_lingers; then
        # polkit usually lets a user enable lingering for themselves; fall
        # back to sudo (prompting if needed) when it does not, e.g. over SSH.
        if ! loginctl enable-linger "$user" 2>/dev/null; then
          if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
            echo "Enabling lingering for $user needs administrator rights:"
            sudo loginctl enable-linger "$user" ||
              fail "could not enable lingering. Ask an administrator to run: sudo loginctl enable-linger $user"
          else
            fail "could not enable lingering. Ask an administrator to run: sudo loginctl enable-linger $user"
          fi
        fi
      fi
      echo "Autostart is on: LocalAI starts at boot and keeps running after you log out."
      ;;
    off)
      systemctl --user disable "$SERVICE_UNIT" >/dev/null ||
        fail "could not disable $SERVICE_UNIT"
      echo "Autostart is off: LocalAI no longer starts at boot."
      if user_lingers; then
        echo "Lingering stays on for $user because other user services may rely on it."
        echo "To turn it off as well: loginctl disable-linger $user"
      fi
      ;;
    status)
      read -r enabled linger < <(autostart_state)
      echo "Service enabled: $enabled"
      echo "Lingering (runs without a login session): $linger"
      if [ "$enabled" = yes ] && [ "$linger" = yes ]; then
        echo "Autostart: on (starts at boot, survives logout)"
      elif [ "$enabled" = yes ]; then
        echo "Autostart: only while you are logged in. Run 'localai autostart on' to keep it running after logout and start it at boot."
      else
        echo "Autostart: off. Run 'localai autostart on' to start LocalAI at boot."
      fi
      ;;
    *)
      fail "usage: localai autostart [on|off|status]"
      ;;
  esac
}

status_cmd() {
  local enabled linger
  if has_user_service; then
    print_service_details "systemd user service"
    echo "Systemd service:"
    systemctl --user status "$SERVICE_UNIT" --no-pager || true
    echo
    read -r enabled linger < <(autostart_state)
    if [ "$linger" != yes ]; then
      echo "Note: LocalAI stops when you log out and does not start at boot. Run 'localai autostart on' to change that."
    elif [ "$enabled" != yes ]; then
      echo "Note: LocalAI does not start at boot. Run 'localai autostart on' to change that."
    fi
    echo "Note: systemd supervises the llama-swap process; the process check below is authoritative."
  else
    print_service_details "helper script"
  fi
  pid_status
}

check_cmd() {
  local base model candidate models_json chat_response chat=0

  if [ "$#" -eq 1 ] && [ "${1:-}" = "--chat" ]; then
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
  api_auth_curl_args

  echo
  echo "API models:"
  if ! models_json="$(curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$base/v1/models")"; then
    fail "API did not respond at $base/v1/models"
  fi
  local model_ids
  if ! model_ids="$(jq -r '.data[]?.id' <<<"$models_json")"; then
    fail "API returned an invalid JSON response from $base/v1/models"
  fi
  printf '%s\n' "$model_ids"

  if [ "$chat" -eq 1 ]; then
    model=""
    while IFS= read -r candidate; do
      if [ -z "$candidate" ] || [ "$candidate" = "null" ]; then
        continue
      fi
      if [ "$(localai_model_type "$candidate")" = chat ]; then
        model="$candidate"
        break
      fi
    done < <(jq -r '.data[]?.id' <<<"$models_json")
    if [ -z "$model" ] || [ "$model" = "null" ]; then
      fail "no model is available for chat check"
    fi
    echo
    echo "Chat check ($model):"
    # Reasoning models (Qwen3, DeepSeek-R1, ...) spend a small token budget on
    # thinking and return empty content, so ask templates that support it to
    # skip thinking and leave room for a short answer either way.
    if ! chat_response="$(curl "${AUTH_CURL_ARGS[@]}" --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, messages: [{role: "user", content: "Reply with OK"}], max_tokens: 64, stream: false, chat_template_kwargs: {enable_thinking: false}}')")"; then
      fail "chat completion failed for $model at $base/v1/chat/completions"
    fi
    local chat_text reasoning_text
    if ! chat_text="$(jq -r '[.choices[0].message.content, .choices[0].text] | map(select(type == "string" and test("\\S"))) | .[0] // ""' <<<"$chat_response")" ||
      ! reasoning_text="$(jq -r '.choices[0].message.reasoning_content // "" | strings' <<<"$chat_response")"; then
      fail "chat completion for $model returned an invalid JSON response"
    fi
    if [ -n "$chat_text" ]; then
      printf '%s\n' "$chat_text"
    elif [[ "$reasoning_text" =~ [^[:space:]] ]]; then
      echo "(no answer yet: the model used the whole check budget for reasoning; the API works)"
    else
      fail "chat completion for $model returned an empty reply"
    fi
  fi
}

# llama-swap and llama-server always write to $LOG_FILE (start.sh redirects
# them), so follow that file even under systemd. The user journal only holds
# the unit's start/stop lines, and distributions with a volatile journal (no
# /var/log/journal, the RHEL family default) keep no user journal at all.
logs_cmd() {
  if has_user_service; then
    echo "Following $LOG_FILE (service start/stop events: journalctl --user -u $SERVICE_UNIT)" >&2
  fi
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  tail -f "$LOG_FILE"
}
