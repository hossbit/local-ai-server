usage() {
  cat <<EOF
Usage: localai COMMAND

Commands:
  start       Start the LocalAI service
  stop        Stop the LocalAI service
  restart     Restart the LocalAI service
  status      Show service status
  check       Check process, port, and API health
  logs        Follow service logs
  models      List installed GGUF models
  suggest     Suggest runtime settings for installed models
  load        Load one model, or all installed models
  unload      Unload one loaded model, or all loaded models
  update      Update llama.cpp, llama-swap, and helper scripts
  version     Show LocalAI and component versions
  uninstall   Uninstall LocalAI
  help        Show this help
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

has_user_service() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user cat "$LOCALAI_SERVICE_NAME" >/dev/null 2>&1
}

print_service_details() {
  local method="$1"

  echo "LocalAI service details:"
  echo "  method: $method"
  echo "  service: $LOCALAI_SERVICE_NAME"
  echo "  service file: $SERVICE_FILE"
  echo "  install dir: $AI_DIR"
  echo "  API: http://${LOCALAI_LISTEN_HOST}:$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALAI_DEFAULT_PORT")"
  echo "  log: $LOG_FILE"
}

pid_status() {
  local pid command port

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALAI_DEFAULT_PORT")"
  if [ -f "$PID_FILE" ]; then
    pid="$(<"$PID_FILE")"
    if pid_file_matches_process "$PID_FILE" "$PID_START_FILE"; then
      command="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
      if [[ "$command" == *llama-swap* ]]; then
        echo "LocalAI process: running (llama-swap PID $pid)"
      else
        echo "LocalAI process: stale PID file; PID $pid belongs to ${command:-another process}"
      fi
    else
      echo "LocalAI process: not running; stale PID file exists at $CONF_DIR/$LOCALAI_PID_FILE"
    fi
  else
    echo "LocalAI process: not running (no PID file)"
  fi
  echo "API: http://${LOCALAI_LISTEN_HOST}:$port"
  if port_is_listening "$port"; then
    echo "Port: listening"
  else
    echo "Port: not listening"
  fi
}

api_base_url() {
  api_base_url_for_port_file "$PORT_FILE"
}

require_api_tools() {
  command -v curl >/dev/null 2>&1 || fail "curl is required for model load/unload commands"
  command -v jq >/dev/null 2>&1 || fail "jq is required for model load/unload commands"
}
