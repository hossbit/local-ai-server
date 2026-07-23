# shellcheck shell=bash disable=SC2154

key_usage() {
  cat <<EOF
Usage: localai key COMMAND [ARGS]

Commands:
  create [NAME]   Create a new API key (name defaults to "default")
  list            List keys; secrets are masked
  revoke KEY_ID   Revoke a key
  rotate KEY_ID   Create a replacement for KEY_ID, then revoke it
  help            Show this help

A key's full secret is printed once, right after it is created or
rotated, and cannot be recovered afterward. 'localai key list' only
ever shows a masked fingerprint.

With no active keys, the API stays unauthenticated (today's default).
Creating the first key turns on Bearer-token authentication for every
request. See README.md for curl/OpenAI-client examples.
EOF
}

key_cmd() {
  local sub="${1:-help}"

  [ "$#" -eq 0 ] || shift

  case "$sub" in
    create) key_create_cmd "$@" ;;
    list) key_list_cmd "$@" ;;
    revoke) key_revoke_cmd "$@" ;;
    rotate) key_rotate_cmd "$@" ;;
    help|-h|--help) key_usage ;;
    *)
      key_usage >&2
      return 2
      ;;
  esac
}

api_key_registry_content_from_rows() {
  local rows="$1"

  if [ -n "$rows" ]; then
    printf 'version\t1\n%s' "$rows"
  else
    printf 'version\t1'
  fi
}

# key_activate: regenerate config.yaml from the current model set and key
# registry, then restart only if the running service would see a different
# config (same idempotence rule 'localai reload' already uses). When the
# service isn't running, it just refreshes config.yaml for the next start.
key_activate() {
  local rebuild="$BIN_DIR/rebuild-config.sh"
  local candidate candidate_keys config_same=0 keys_same=0

  [ -x "$rebuild" ] || { echo "Error: missing helper: $rebuild" >&2; return 1; }

  candidate="$(mktemp "${TMPDIR:-/tmp}/localai-key.XXXXXX")" || return 1
  candidate_keys="$(mktemp "${TMPDIR:-/tmp}/localai-key-keys.XXXXXX")" || {
    rm -f "$candidate"
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -f '$candidate' '$candidate_keys'" RETURN

  if ! "$rebuild" "$candidate" "$candidate_keys" >/dev/null; then
    echo "Error: failed to rebuild configuration from the updated key registry." >&2
    return 1
  fi

  [ -f "$CONFIG" ] && diff -q "$CONFIG" "$candidate" >/dev/null 2>&1 && config_same=1
  if [ -f "$KEYS_FILE" ] || [ -f "$candidate_keys" ]; then
    [ -f "$KEYS_FILE" ] && [ -f "$candidate_keys" ] &&
      diff -q "$KEYS_FILE" "$candidate_keys" >/dev/null 2>&1 && keys_same=1
  else
    keys_same=1
  fi
  [ "$config_same" -eq 1 ] && [ "$keys_same" -eq 1 ] && return 0

  if pid_file_matches_process "$PID_FILE" "$PID_START_FILE" || has_user_service; then
    service_cmd restart
  else
    mkdir -p "$CONF_DIR" "$KEYS_DIR"
    cp "$candidate" "$CONFIG"
    chmod 600 "$CONFIG" 2>/dev/null || true
    if [ -f "$candidate_keys" ]; then
      cp "$candidate_keys" "$KEYS_FILE"
      chmod 600 "$KEYS_FILE" 2>/dev/null || true
    else
      rm -f "$KEYS_FILE"
    fi
    echo "Configuration updated; it will take effect on the next 'localai start'."
  fi
}

key_print_new_secret() {
  local name="$1" id="$2" created="$3" secret="$4"
  local port

  port="$([ -f "$PORT_FILE" ] && cat "$PORT_FILE" || printf '%s' "$LOCALAI_DEFAULT_PORT")"

  echo
  echo "$(c 32 "Key created:") $name"
  echo "  id:      $(c 2 "$id")"
  echo "  created: $(c 2 "$created")"
  echo
  printf '%s\n' "$(c 33 "Save this key now - it will not be shown again:")"
  echo
  echo "    $(c 1 "$secret")"
  echo
  echo "Use it as a Bearer token:"
  echo "  curl http://${LOCALAI_LISTEN_HOST}:${port}/v1/models \\"
  echo "    -H \"Authorization: Bearer $secret\""
  echo
  echo "Run 'localai key list' to see all keys (masked)."
}

key_create_cmd() {
  local name="${1:-default}"

  [ "$#" -le 1 ] || fail "usage: localai key create [NAME]"
  api_key_validate_name "$name" ||
    fail "invalid key name: '$name' (use 1-64 letters, digits, spaces, '.', '_', '-')"

  local registry existing_rows secret id created content attempt=0

  registry="$(api_key_registry_path)"
  mkdir -p "$CONF_DIR"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"
  existing_rows="$(api_key_registry_rows "$registry")"

  while :; do
    secret="$(api_key_generate_secret)" ||
      fail "no cryptographic random source available (need openssl or /dev/urandom)"
    id="$(api_key_generate_id "$secret")"
    grep -q "^${id}$(printf '\t')" <<<"$existing_rows" 2>/dev/null || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "could not generate a unique key id after $attempt attempts"
  done

  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local new_row rows
  new_row="$(printf '%s\t%s\t%s\tactive\t%s' "$id" "$name" "$created" "$secret")"
  if [ -n "$existing_rows" ]; then
    rows="$existing_rows"$'\n'"$new_row"
  else
    rows="$new_row"
  fi

  content="$(api_key_registry_content_from_rows "$rows")"
  api_key_registry_write_atomic "$registry" "$content" || fail "failed to save key registry"

  echo "Applying configuration..."
  key_activate || echo "Warning: key was saved, but activation failed; run 'localai reload' to retry." >&2

  key_print_new_secret "$name" "$id" "$created" "$secret"
}

key_list_cmd() {
  [ "$#" -eq 0 ] || fail "usage: localai key list"

  local registry
  registry="$(api_key_registry_path)"
  if [ ! -f "$registry" ]; then
    echo "No API keys configured. The API is unauthenticated."
    return 0
  fi
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"

  local id name created status secret masked status_display i active_count=0
  local -a col_id=() col_name=() col_created=() col_status=() col_masked=()
  local w_id=2 w_name=4 w_created=7 w_status=6

  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$status" = active ]; then
      masked="$(api_key_mask "$secret")"
      active_count=$((active_count + 1))
    else
      masked="-"
    fi

    col_id+=("$id")
    col_name+=("$name")
    col_created+=("$created")
    col_status+=("$status")
    col_masked+=("$masked")

    [ "${#id}" -le "$w_id" ] || w_id="${#id}"
    [ "${#name}" -le "$w_name" ] || w_name="${#name}"
    [ "${#created}" -le "$w_created" ] || w_created="${#created}"
    [ "${#status}" -le "$w_status" ] || w_status="${#status}"
  done < <(api_key_registry_rows "$registry")

  if [ "${#col_id[@]}" -eq 0 ]; then
    echo "No API keys configured. The API is unauthenticated."
    return 0
  fi

  printf "%-${w_id}s  %-${w_name}s  %-${w_created}s  %-${w_status}s  %s\n" \
    "ID" "NAME" "CREATED" "STATUS" "KEY"

  for ((i = 0; i < ${#col_id[@]}; i++)); do
    status_display="$(printf "%-${w_status}s" "${col_status[i]}")"
    if [ "${col_status[i]}" = active ]; then
      status_display="$(c 32 "$status_display")"
    else
      status_display="$(c 2 "$status_display")"
    fi
    printf "%-${w_id}s  %-${w_name}s  %-${w_created}s  %s  %s\n" \
      "${col_id[i]}" "${col_name[i]}" "${col_created[i]}" "$status_display" "${col_masked[i]}"
  done

  echo
  if [ "$active_count" -gt 0 ]; then
    echo "$active_count active key(s). The API requires a valid Bearer token."
  else
    echo "No active keys. The API is unauthenticated."
  fi
}

key_revoke_cmd() {
  local target="${1:-}"

  [ -n "$target" ] || fail "usage: localai key revoke KEY_ID"
  [ "$#" -eq 1 ] || fail "usage: localai key revoke KEY_ID"

  local registry
  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || fail "no such key: $target"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"

  local id name created status secret found=0 revoked_name="" row rows=""
  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$id" = "$target" ]; then
      found=1
      [ "$status" != revoked ] || fail "key already revoked: $target"
      revoked_name="$name"
      row="$(printf '%s\t%s\t%s\trevoked\t-' "$id" "$name" "$created")"
    else
      row="$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$name" "$created" "$status" "$secret")"
    fi
    rows="$rows$row"$'\n'
  done < <(api_key_registry_rows "$registry")
  rows="${rows%$'\n'}"

  [ "$found" -eq 1 ] || fail "no such key: $target"

  local content
  content="$(api_key_registry_content_from_rows "$rows")"
  api_key_registry_write_atomic "$registry" "$content" || fail "failed to save key registry"

  echo "Applying configuration..."
  key_activate || echo "Warning: key was revoked, but activation failed; run 'localai reload' to retry." >&2

  echo "$(c 31 "Revoked:") $target ($revoked_name)"
}

key_rotate_cmd() {
  local target="${1:-}"

  [ -n "$target" ] || fail "usage: localai key rotate KEY_ID"
  [ "$#" -eq 1 ] || fail "usage: localai key rotate KEY_ID"

  local registry
  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || fail "no such key: $target"
  api_key_registry_validate "$registry" || fail "key registry is malformed: $registry"
  local existing_rows
  existing_rows="$(api_key_registry_rows "$registry")"

  local id name created status secret found=0 old_name="" row rows=""
  while IFS=$'\t' read -r id name created status secret; do
    [ -n "$id" ] || continue
    if [ "$id" = "$target" ]; then
      found=1
      [ "$status" = active ] || fail "cannot rotate a revoked key: $target"
      old_name="$name"
      row="$(printf '%s\t%s\t%s\trevoked\t-' "$id" "$name" "$created")"
    else
      row="$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$name" "$created" "$status" "$secret")"
    fi
    rows="$rows$row"$'\n'
  done <<<"$existing_rows"

  [ "$found" -eq 1 ] || fail "no such key: $target"

  local new_secret new_id new_created attempt=0
  while :; do
    new_secret="$(api_key_generate_secret)" ||
      fail "no cryptographic random source available (need openssl or /dev/urandom)"
    new_id="$(api_key_generate_id "$new_secret")"
    grep -q "^${new_id}$(printf '\t')" <<<"$existing_rows" 2>/dev/null || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "could not generate a unique key id after $attempt attempts"
  done
  new_created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rows="$rows$(printf '%s\t%s\t%s\tactive\t%s' "$new_id" "$old_name" "$new_created" "$new_secret")"

  local content
  content="$(api_key_registry_content_from_rows "$rows")"
  api_key_registry_write_atomic "$registry" "$content" || fail "failed to save key registry"

  echo "Applying configuration..."
  key_activate || echo "Warning: key was rotated, but activation failed; run 'localai reload' to retry." >&2

  echo "$(c 2 "Revoked previous key:") $target"
  key_print_new_secret "$old_name" "$new_id" "$new_created" "$new_secret"
}
