# shellcheck shell=bash disable=SC2154

models_cmd() {
  local loaded_models="" loaded_available=0 loaded_checked=0 id rel path status loaded
  local -A loaded_model_set=()

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

  while IFS=$'\t' read -r id rel path; do
    [ -n "$id" ] || continue
    status=""
    if [ "$loaded_available" -eq 1 ]; then
      if [[ -n "${loaded_model_set[$id]+x}" || -n "${loaded_model_set[$rel]+x}" ]]; then
        status=" [loaded]"
      else
        status=" [not loaded]"
      fi
    fi
    printf '%s -> %s%s\n' "$id" "$rel" "$status"
  done < <(localai_model_entries "$MODELS_DIR")

  if [ "$loaded_checked" -eq 1 ] && [ "$loaded_available" -eq 0 ]; then
    echo
    echo "Loaded state unavailable: API is not reachable at $(api_base_url)/running"
  elif [ "$loaded_checked" -eq 0 ]; then
    echo
    echo "Loaded state unavailable: curl and jq are required"
  fi
}

api_models() {
  curl --max-time 10 -fsS "$(api_base_url)/v1/models" | jq -r '.data[]?.id'
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
  if model_is_embedding "$model"; then
    curl --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/embeddings" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg model "$model" '{model: $model, input: "ok"}')" >/dev/null
  else
    curl --max-time "$LOCALAI_HEALTH_CHECK_TIMEOUT" -fsS "$base/v1/chat/completions" \
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
  curl --max-time 10 -fsS "$(api_base_url)/running" |
    jq -r '.running[]? | if type == "object" then .model // .id // .name // empty else . end'
}

url_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

unload_one_model() {
  local model="$1"
  local encoded_model

  encoded_model="$(url_encode "$model")"
  curl --max-time 30 -fsS -X POST "$(api_base_url)/api/models/unload/${encoded_model}" >/dev/null
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

    curl --max-time 30 -fsS -X POST "$(api_base_url)/api/models/unload" >/dev/null
    echo "Unloaded all loaded models."
    return 0
  fi

  unload_one_model "$target"
}
