# shellcheck shell=bash disable=SC2034,SC2154

models_cmd() {
  local loaded_models="" loaded_available=0 loaded_checked=0 id rel path status loaded
  local -A loaded_model_set=()
  local -a col_model=() col_type=() col_size=() col_status=() col_file=()
  local model_type model_bytes size_display use_color=0 loaded_count=0
  local w_model=5 w_type=4 w_size=4 w_status=6 i status_display

  if [ ! -d "$MODELS_DIR" ]; then
    echo "Models directory does not exist: $MODELS_DIR"
    return 0
  fi

  if ! localai_has_model_entries "$MODELS_DIR"; then
    echo "No GGUF models found in $MODELS_DIR"
    return 0
  fi

  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    loaded_checked=1
    if loaded_models="$(running_models 2>/dev/null)"; then
      loaded_available=1
      while IFS= read -r loaded; do
        [ -n "$loaded" ] || continue
        loaded_model_set["$loaded"]=1
      done <<< "$loaded_models"
    fi
  fi

  [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && use_color=1

  while IFS=$'\t' read -r id rel path; do
    [ -n "$id" ] || continue

    if [[ "${id,,}" == *qwen3*embedding* ]] || model_is_embedding_name "$id"; then
      model_type="embedding"
    else
      model_type="chat"
    fi

    model_bytes="$(localai_model_bytes "$path")"
    size_display="$(format_bytes_gib "$model_bytes")"

    if [ "$loaded_available" -eq 1 ]; then
      if [[ -n "${loaded_model_set[$id]+x}" || -n "${loaded_model_set[$rel]+x}" ]]; then
        status="loaded"
        loaded_count=$((loaded_count + 1))
      else
        status="not loaded"
      fi
    elif [ "$loaded_checked" -eq 1 ]; then
      status="unknown"
    else
      status="-"
    fi

    col_model+=("$id")
    col_type+=("$model_type")
    col_size+=("$size_display")
    col_status+=("$status")
    col_file+=("$rel")

    [ "${#id}" -le "$w_model" ] || w_model="${#id}"
    [ "${#model_type}" -le "$w_type" ] || w_type="${#model_type}"
    [ "${#size_display}" -le "$w_size" ] || w_size="${#size_display}"
    [ "${#status}" -le "$w_status" ] || w_status="${#status}"
  done < <(localai_model_entries "$MODELS_DIR")

  printf "%-${w_model}s  %-${w_type}s  %-${w_size}s  %-${w_status}s  %s\n" \
    "MODEL" "TYPE" "SIZE" "STATUS" "FILE"

  for ((i = 0; i < ${#col_model[@]}; i++)); do
    status_display="$(printf "%-${w_status}s" "${col_status[i]}")"
    if [ "$use_color" -eq 1 ] && [ "${col_status[i]}" = "loaded" ]; then
      status_display=$'\033[32m'"$status_display"$'\033[0m'
    fi
    printf "%-${w_model}s  %-${w_type}s  %-${w_size}s  %s  %s\n" \
      "${col_model[i]}" "${col_type[i]}" "${col_size[i]}" "$status_display" "${col_file[i]}"
  done

  if [ "$loaded_available" -eq 1 ]; then
    echo
    echo "$loaded_count of ${#col_model[@]} model(s) loaded"
  elif [ "$loaded_checked" -eq 1 ]; then
    echo
    echo "Loaded state unavailable: API is not reachable at $(api_base_url)/running"
  else
    echo
    echo "Loaded state unavailable: curl and jq are required"
  fi
}

api_models() {
  api_auth_curl_args
  curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$(api_base_url)/v1/models" | jq -r '.data[]?.id'
}

installed_model_exists() {
  local model="$1"

  localai_model_file_for_id "$MODELS_DIR" "$model" >/dev/null
}

model_is_embedding() {
  model_is_embedding_name "$1"
}

load_one_model() {
  local model="$1"
  local base

  base="$(api_base_url)"
  api_auth_curl_args
  if model_is_embedding "$model"; then
    curl "${AUTH_CURL_ARGS[@]}" --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/embeddings" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, input: "ok"}')" >/dev/null
  else
    curl "${AUTH_CURL_ARGS[@]}" --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, messages: [{role: "user", content: "Reply with OK"}], max_tokens: 1, stream: false}')" >/dev/null
  fi
  echo "Loaded: $model"
}

load_cmd() {
  local target="${1:-}" model loaded=0 failed=0

  [ -n "$target" ] || fail "usage: localai load MODEL|all"
  [ "$#" -eq 1 ] || fail "usage: localai load MODEL|all"
  require_api_tools

  if [ "$target" = "all" ]; then
    while IFS= read -r model; do
      [ -n "$model" ] || continue
      loaded=1
      if ! load_one_model "$model"; then
        echo "Error: failed to load $model" >&2
        failed=1
      fi
    done < <(api_models)
    [ "$loaded" -eq 1 ] || fail "no models are available from $(api_base_url)/v1/models"
    return "$failed"
  fi

  installed_model_exists "$target" || fail "model not found: $target"
  load_one_model "$target"
}

running_models() {
  api_auth_curl_args
  curl "${AUTH_CURL_ARGS[@]}" --max-time 10 -fsS "$(api_base_url)/running" |
    jq -r '.running[]? | if type == "object" then .model // .id // .name // empty else . end'
}

url_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

unload_one_model() {
  local model="$1"
  local encoded_model

  encoded_model="$(url_encode "$model")"
  api_auth_curl_args
  curl "${AUTH_CURL_ARGS[@]}" --max-time 30 -fsS -X POST "$(api_base_url)/api/models/unload/${encoded_model}" >/dev/null
  echo "Unloaded: $model"
}

unload_cmd() {
  local target="${1:-}" model unloaded=0

  [ -n "$target" ] || fail "usage: localai unload MODEL|all"
  [ "$#" -eq 1 ] || fail "usage: localai unload MODEL|all"
  require_api_tools

  if [ "$target" = "all" ]; then
    while IFS= read -r model; do
      [ -n "$model" ] || continue
      unloaded=1
    done < <(running_models)

    if [ "$unloaded" -eq 0 ]; then
      echo "No loaded models to unload."
      return 0
    fi

    api_auth_curl_args
    curl "${AUTH_CURL_ARGS[@]}" --max-time 30 -fsS -X POST "$(api_base_url)/api/models/unload" >/dev/null
    echo "Unloaded all loaded models."
    return 0
  fi

  unload_one_model "$target"
}
