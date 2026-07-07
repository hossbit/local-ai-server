#!/usr/bin/env bash
# shellcheck disable=SC2154

expand_path() {
  local value="$1"

  case "$value" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${value:2}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

resolve_ai_dir() {
  if [ -n "${LOCALAI_DIR:-}" ]; then
    expand_path "$LOCALAI_DIR"
  elif [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
    cd "$SCRIPT_DIR/.." && pwd
  elif [ -f "$SCRIPT_DIR/install-local-ai.sh" ]; then
    expand_path "$LOCALAI_DEFAULT_DIR"
  else
    printf '%s\n' "$SCRIPT_DIR"
  fi
}

resolve_llama_swap_paths() {
  if [ -z "${LLAMA_SWAP_INSTALL_PATH:-}" ] || [ "$LLAMA_SWAP_INSTALL_PATH" = "/usr/local/bin/llama-swap" ]; then
    LLAMA_SWAP_INSTALL_PATH="$BIN_DIR/llama-swap"
  fi
  LLAMA_SWAP_BIN="${LLAMA_SWAP_BIN:-$LLAMA_SWAP_INSTALL_PATH}"
}

source_localai_lib() {
  local name="$1"
  local candidate

  for candidate in "$SCRIPT_DIR/lib/$name" "$SCRIPT_DIR/../lib/$name"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: $name" >&2
  exit 1
}

api_base_url_for_port_file() {
  local port_file="$1"
  local port

  port="$([ -f "$port_file" ] && cat "$port_file" || printf '%s' "$LOCALAI_DEFAULT_PORT")"
  printf 'http://%s:%s' "$LOCALAI_LISTEN_HOST" "$port"
}

port_is_listening() {
  local port="$1"
  local port_hex

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return "$?"
  fi

  port_hex="$(printf '%04X' "$port")"
  awk -v port="$port_hex" '
    $4 == "0A" {
      n = split($2, address, ":")
      if (toupper(address[n]) == port) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

model_is_embedding_name() {
  local model="${1,,}"

  case "$model" in
    *qwen3*embedding*|*embedding*|*embed*|*bge*) return 0 ;;
    e5-*|*[-_.]e5[-_.]*|*[-_.]e5) return 0 ;;
    *) return 1 ;;
  esac
}

process_start_time() {
  local pid="$1"

  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

pid_file_matches_process() {
  local pid_file="$1"
  local start_file="$2"
  local pid recorded_start current_start

  [ -f "$pid_file" ] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -f "$start_file" ]; then
    recorded_start="$(<"$start_file")"
    current_start="$(process_start_time "$pid")"
    [ -n "$current_start" ] && [ "$recorded_start" = "$current_start" ] || return 1
  fi

  return 0
}
