# shellcheck shell=bash disable=SC2154

backend_usage() {
  cat <<EOF
Usage: localai backend COMMAND

Commands:
  list             List installed backends -- version, disk size, and which
                   one is active
  install BACKEND  Install a backend without switching to it (cpu, vulkan,
                   rocm, openvino, sycl-fp16, sycl-fp32, cuda, auto). Use
                   'localai switch BACKEND' instead to install AND activate.
  help             Show this help
EOF
}

backend_cmd() {
  local sub="${1:-help}"

  [ "$#" -eq 0 ] || shift

  case "$sub" in
    list) backend_list_cmd "$@" ;;
    install) backend_install_cmd "$@" ;;
    help|-h|--help) backend_usage ;;
    *)
      backend_usage >&2
      return 2
      ;;
  esac
}

backend_list_cmd() {
  local active="" backend dir size version

  [ "$#" -eq 0 ] || fail "usage: localai backend list"

  [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ] && active="$(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"

  if [ ! -d "$BIN_DIR/llama.cpp.d" ] ||
    [ -z "$(find "$BIN_DIR/llama.cpp.d" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
    echo "No backends installed."
    return 0
  fi

  printf '%-3s %-10s %-22s %s\n' "" "BACKEND" "VERSION" "SIZE"
  while IFS= read -r dir; do
    backend="$(basename "$dir")"
    version="$(llama_cpp_backend_display_version "$backend")"
    size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
    printf '%-3s %-10s %-22s %s\n' \
      "$([ "$backend" = "$active" ] && printf '*' || printf '')" \
      "$backend" \
      "${version#version: }" \
      "${size:-?}"
  done < <(find "$BIN_DIR/llama.cpp.d" -mindepth 1 -maxdepth 1 -type d | sort)
}

# backend_install_cmd: installs a backend into its own slot
# ($BIN_DIR/llama.cpp.d/<backend>) without switching to it -- unlike
# `localai switch`, which activates whatever it installs. Reuses the normal
# update flow (same fallback `switch` uses for a not-yet-cached backend),
# then explicitly restores whichever backend was active before, and only
# restarts the service if it was actually running before this started.
backend_install_cmd() {
  local requested="${1:-}" resolved original_backend was_running=0 status=0

  if [ -z "$requested" ] || [ "$#" -ne 1 ]; then
    fail "usage: localai backend install <backend>  (cpu, vulkan, rocm, openvino, sycl-fp16, sycl-fp32, cuda, auto)"
  fi

  resolved="$requested"
  [ "$requested" = "auto" ] && resolved="$(cuda_resolve_auto_backend)"

  if [ -x "$BIN_DIR/llama.cpp.d/$resolved/llama-server" ]; then
    echo "$resolved backend is already installed."
    return 0
  fi

  [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ] && original_backend="$(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"
  pid_file_matches_process "$PID_FILE" "$PID_START_FILE" && was_running=1

  echo "Installing $resolved backend without switching to it"
  LLAMA_CPP_BACKEND="$requested" update_cmd --no-start || status=$?

  if [ -n "$original_backend" ]; then
    LLAMA_CPP_BACKEND="$original_backend" activate_llama_cpp_backend
  fi
  [ "$was_running" -eq 1 ] && service_cmd restart

  return "$status"
}
