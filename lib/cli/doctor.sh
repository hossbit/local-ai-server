# shellcheck shell=bash disable=SC2153,SC2154

doctor_ok() { echo "  ok    $*"; }
doctor_warn() { echo "  warn  $*"; DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)); }
doctor_bad() { echo "  FAIL  $*"; DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1)); }

# doctor_cmd: read-only diagnosis of the install, models, service and API.
# --chat adds the same round-trip as `localai check --chat`.
doctor_cmd() {
  local chat=0 tool backend="" devices count=0 broken free enabled linger

  if [ "$#" -eq 1 ] && [ "$1" = "--chat" ]; then
    chat=1
  elif [ "$#" -gt 0 ]; then
    fail "usage: localai doctor [--chat]"
  fi
  DOCTOR_ERRORS=0
  DOCTOR_WARNINGS=0
  echo "LocalAI doctor ($LOCALAI_VERSION, $AI_DIR)"

  for tool in curl jq tar; do
    command -v "$tool" >/dev/null 2>&1 || doctor_bad "$tool is missing; install it with your package manager"
  done

  [ ! -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ] || backend="$(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"
  if llama_server_runs; then
    doctor_ok "llama.cpp runs (backend: ${backend:-unknown})"
    if [ -n "$backend" ] && [ "$backend" != cpu ] && devices="$(llama_server_device_count)"; then
      if [ "$devices" = 0 ]; then
        doctor_warn "the $backend backend finds no GPU; consider: localai backend use cpu"
      else
        doctor_ok "GPU devices: $devices"
      fi
    fi
  else
    doctor_bad "llama.cpp does not run; try: localai update"
  fi
  if [ -x "$LLAMA_SWAP_BIN" ]; then
    doctor_ok "llama-swap is installed"
  else
    doctor_bad "llama-swap is missing; try: localai update"
  fi

  if localai_has_model_entries "$MODELS_DIR"; then
    count="$(localai_model_entries "$MODELS_DIR" 2>/dev/null | wc -l)"
    doctor_ok "models: $count in $MODELS_DIR"
  else
    doctor_warn "no models yet; add one with: localai add FILE.gguf (or ORG/REPO)"
  fi
  while IFS= read -r broken; do
    [ -z "$broken" ] || doctor_warn "broken model link: $broken"
  done < <(find "$MODELS_DIR/" -mindepth 1 -maxdepth 2 -xtype l -print 2>/dev/null)

  free="$(df -Pk "$AI_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "$free" =~ ^[0-9]+$ ]] && [ "$free" -lt $((LOCALAI_DOCTOR_MIN_FREE_GB * 1024 * 1024)) ]; then
    doctor_warn "less than $LOCALAI_DOCTOR_MIN_FREE_GB GB free in $AI_DIR"
  fi

  if has_user_service; then
    read -r enabled linger < <(autostart_state)
    if [ "$enabled" = yes ] && [ "$linger" = yes ]; then
      doctor_ok "autostart is on"
    else
      doctor_warn "LocalAI does not start at boot or stops at logout; run: localai autostart on"
    fi
  else
    doctor_warn "no systemd user service found"
  fi

  if api_responds; then
    doctor_ok "API responds at $(api_base_url)"
  elif localai_service_running; then
    doctor_bad "LocalAI runs but the API does not respond; see: localai logs"
  else
    doctor_warn "LocalAI is not running; start it with: localai start"
  fi

  echo
  echo "$DOCTOR_ERRORS error(s), $DOCTOR_WARNINGS warning(s)."
  if [ "$chat" -eq 1 ]; then
    echo
    (check_cmd --chat) || DOCTOR_ERRORS=$((DOCTOR_ERRORS + 1))
  fi
  [ "$DOCTOR_ERRORS" -eq 0 ]
}
