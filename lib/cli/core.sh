# shellcheck shell=bash disable=SC2154

usage() {
  cat <<EOF
Usage: localai COMMAND

  start       Start LocalAI
  stop        Stop LocalAI
  status      Show service and API state
  models      List installed models
  add         Add a model: a local GGUF file, or ORG/REPO:QUANT from Hugging Face
  logs        Follow the server log
  doctor      Find problems; --chat also tests a chat reply
  backend     List or choose the engine: cpu, vulkan, cuda, ...
  update      Update LocalAI and its engine
  help        Show this help; 'help --all' shows every command

First steps: localai add FILE.gguf, then localai start
EOF
}

usage_all() {
  cat <<EOF
Usage: localai COMMAND

Commands:
  start       Start the LocalAI service
  stop        Stop the LocalAI service
  restart     Restart the LocalAI service
  reload      Rescan models and restart only if config.yaml would change
  status      Show service status
  autostart   Start at boot and keep running after logout (on, off, status)
  doctor      Diagnose the install, models, service and API
              Use --chat for a chat completion round-trip
  add         Link a local GGUF file or folder, or download ORG/REPO:QUANT
              from Hugging Face ('localai add --help')
  logs        Follow service logs
  models      List installed GGUF models
  ui          Print the llama-swap Web UI URL, or a model's llama.cpp chat
              UI URL with 'localai ui MODEL'; add --open to launch a browser
              Dashboard shortcuts: --chat/--models/--logs/--performance
              --hardware/--settings/--activity: jump directly to a dashboard section
  suggest     Suggest settings; --benchmark MODEL measures current speed
  load        Load one model, or all installed models
  unload      Unload one loaded model, or all loaded models
  key         Manage API keys (create, list, revoke, rotate)
  backend     Manage llama.cpp backends: list, use BACKEND, install BACKEND
              (cpu, vulkan, cuda, rocm, openvino, sycl-fp16, sycl-fp32, auto)
  update      Update llama.cpp, llama-swap, and helper scripts
              Use --all to update every installed backend, not just the active one
              Use --check to only report available updates (changes nothing)
              A failed restart restores the previous versions automatically
              Use --rollback to return to the versions the last update
              replaced (run again to return to the newer ones)
  version     Show LocalAI and component versions
  uninstall   Uninstall LocalAI
  help        Show the common commands; --all shows this list

Older names still work: check, switch, rollback.
EOF
}

help_cmd() {
  case "${1:-}" in
    '') usage ;;
    -a|--all|all) usage_all ;;
    *) fail "usage: localai help [--all]" ;;
  esac
}

fail() {
  echo "Error: $*" >&2
  exit 1
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
