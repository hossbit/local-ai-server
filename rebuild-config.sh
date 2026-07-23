#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localai.conf"
elif [ -f "$SCRIPT_DIR/localai.conf" ]; then
  # shellcheck source=localai.conf
  . "$SCRIPT_DIR/localai.conf"
else
  echo "Error: localai.conf not found." >&2
  exit 1
fi
source_localai_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: common.sh" >&2
  exit 1
}
source_localai_common

AI_DIR="$(resolve_ai_dir)"
CONF_DIR="$AI_DIR/$LOCALAI_CONF_SUBDIR"
CONFIG="${1:-$CONF_DIR/$LOCALAI_CONFIG_FILE}"
MODELS_DIR="$AI_DIR/$LOCALAI_MODELS_SUBDIR"
OVERRIDES_DIR="$CONF_DIR/${MODELS_OVERRIDE_SUBDIR:-$LOCALAI_MODELS_OVERRIDE_SUBDIR}"
BIN="$AI_DIR/$LOCALAI_BIN_SUBDIR/llama-server"
CTX_SIZE="${CTX_SIZE:-$LOCALAI_CTX_SIZE}"
N_GPU_LAYERS="${N_GPU_LAYERS:-$LOCALAI_N_GPU_LAYERS}"
THREADS="${THREADS:-$LOCALAI_THREADS}"
CACHE_TYPE_K="${CACHE_TYPE_K:-$LOCALAI_CACHE_TYPE_K}"
CACHE_TYPE_V="${CACHE_TYPE_V:-$LOCALAI_CACHE_TYPE_V}"
PARALLEL="${PARALLEL:-$LOCALAI_PARALLEL}"
BATCH_SIZE="${BATCH_SIZE:-$LOCALAI_BATCH_SIZE}"
UBATCH_SIZE="${UBATCH_SIZE:-$LOCALAI_UBATCH_SIZE}"
FLASH_ATTN="${FLASH_ATTN:-$LOCALAI_FLASH_ATTN}"
JINJA="${JINJA:-$LOCALAI_JINJA}"
MLOCK="${MLOCK:-$LOCALAI_MLOCK}"
NO_MMAP="${NO_MMAP:-$LOCALAI_NO_MMAP}"
EXTRA_LLAMA_ARGS="${EXTRA_LLAMA_ARGS:-$LOCALAI_EXTRA_LLAMA_ARGS}"
SPEC_TYPE="${SPEC_TYPE:-$LOCALAI_SPEC_TYPE}"
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-$LOCALAI_SPEC_DRAFT_N_MAX}"
AUTO_TUNE="${AUTO_TUNE:-$LOCALAI_AUTO_TUNE}"
METRICS_ENABLED="${METRICS_ENABLED:-$LOCALAI_METRICS_ENABLED}"
PRELOAD_MODELS="${PRELOAD_MODELS:-$LOCALAI_PRELOAD_MODELS}"
EMBEDDING_TTL="${EMBEDDING_TTL:-$LOCALAI_EMBEDDING_TTL}"

validate_optional_positive_integer() {
  local name="$1"
  local value="$2"

  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < 1)); then
    echo "Error: $name must be a positive integer when set." >&2
    exit 1
  fi
}

validate_optional_nonnegative_integer() {
  local name="$1"
  local value="$2"

  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $name must be a non-negative integer when set." >&2
    exit 1
  fi
}

validate_bool() {
  local name="$1"
  local value="$2"

  case "$value" in
    0|1) ;;
    *)
      echo "Error: $name must be 0 or 1." >&2
      exit 1
      ;;
  esac
}

validate_spec_type() {
  local name="$1"
  local value="$2"

  case "$value" in
    ""|none|draft-simple|draft-eagle3|draft-mtp|draft-dflash|ngram-simple|ngram-map-k|ngram-map-k4v|ngram-mod|ngram-cache) ;;
    *)
      echo "Error: $name has an unsupported value: $value" >&2
      exit 1
      ;;
  esac
}

trim_ws() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || ((CTX_SIZE < 1)); then
  echo "Error: CTX_SIZE must be a positive integer." >&2
  exit 1
fi

if ! [[ "$N_GPU_LAYERS" =~ ^([0-9]+|auto|all)$ ]]; then
  echo "Error: N_GPU_LAYERS must be a non-negative integer, 'auto', or 'all'." >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
  echo "Error: THREADS must be a non-negative integer." >&2
  exit 1
fi

validate_optional_positive_integer PARALLEL "$PARALLEL"
validate_optional_positive_integer BATCH_SIZE "$BATCH_SIZE"
validate_optional_positive_integer UBATCH_SIZE "$UBATCH_SIZE"
validate_optional_positive_integer SPEC_DRAFT_N_MAX "$SPEC_DRAFT_N_MAX"
validate_optional_nonnegative_integer EMBEDDING_TTL "$EMBEDDING_TTL"
validate_bool FLASH_ATTN "$FLASH_ATTN"
validate_bool JINJA "$JINJA"
validate_bool MLOCK "$MLOCK"
validate_bool NO_MMAP "$NO_MMAP"
validate_bool AUTO_TUNE "$AUTO_TUNE"
validate_bool METRICS_ENABLED "$METRICS_ENABLED"
validate_spec_type SPEC_TYPE "$SPEC_TYPE"

case "$EXTRA_LLAMA_ARGS" in
  *$'\n'*|*$'\r'*)
    echo "Error: EXTRA_LLAMA_ARGS must be a single line." >&2
    exit 1
    ;;
esac

# Flags that never vary per model: concurrency, batching, and template/mmap
# behavior. Per-model tunables (flash-attn, spec-decoding, mmproj, ...) are
# built separately for each model below since auto-tune and models.d
# overrides can change them per model.
COMMON_EXTRA_ARGS=""
[ -z "$PARALLEL" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --parallel $PARALLEL"
[ -z "$BATCH_SIZE" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --batch-size $BATCH_SIZE"
[ -z "$UBATCH_SIZE" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --ubatch-size $UBATCH_SIZE"
[ "$JINJA" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --jinja"
[ "$MLOCK" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --mlock"
[ "$NO_MMAP" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --no-mmap"
[ -z "$EXTRA_LLAMA_ARGS" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      $EXTRA_LLAMA_ARGS"

mkdir -p "$CONF_DIR" "$MODELS_DIR" "$OVERRIDES_DIR"

# API_KEY_REGISTRY is validated before anything is written to $CONFIG, so a
# corrupted registry aborts the rebuild instead of silently generating an
# unauthenticated config over a previously-authenticated one.
API_KEY_REGISTRY="$CONF_DIR/${LOCALAI_API_KEY_FILE:-api-keys.tsv}"
REQUIRE_API_KEY="${LOCALAI_REQUIRE_API_KEY:-0}"
validate_bool REQUIRE_API_KEY "$REQUIRE_API_KEY"

if ! api_key_registry_validate "$API_KEY_REGISTRY"; then
  echo "Refusing to rebuild configuration; $CONFIG was left unchanged." >&2
  exit 1
fi

ACTIVE_API_KEYS="$(api_key_active_named_secrets "$API_KEY_REGISTRY")"
ACTIVE_API_KEY_COUNT=0
[ -z "$ACTIVE_API_KEYS" ] || ACTIVE_API_KEY_COUNT="$(grep -c . <<<"$ACTIVE_API_KEYS")"

if [ "$REQUIRE_API_KEY" = "1" ] && [ "$ACTIVE_API_KEY_COUNT" -eq 0 ]; then
  echo "Error: LOCALAI_REQUIRE_API_KEY=1 but no active API keys exist." >&2
  echo "Create one first: localai key create" >&2
  exit 1
fi

BACKEND="$([ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ] && cat "$CONF_DIR/$LOCALAI_BACKEND_FILE" || printf '%s' "$LOCALAI_DEFAULT_BACKEND")"
RAM_BYTES="$(system_ram_bytes)"
VRAM_BYTES="$(gpu_vram_bytes)"
# A pinned/older LLAMA_CPP_VERSION may predate '-ngl auto' support; detect it
# once so auto-tune falls back to the configured N_GPU_LAYERS instead of
# passing a flag the installed llama-server would reject.
NGL_AUTO_SUPPORTED=0
llama_server_supports_ngl_auto "$BIN" && NGL_AUTO_SUPPORTED=1
if [ "$AUTO_TUNE" = "1" ] && [ "$BACKEND" != "cpu" ] && [ "$NGL_AUTO_SUPPORTED" -eq 0 ]; then
  echo "Note: installed llama-server does not support '-ngl auto'; auto-tune will use N_GPU_LAYERS=$N_GPU_LAYERS for every model instead of per-model fitting." >&2
fi

# Snapshot the global defaults once; the per-model loop resets its working
# copies from these on every iteration so a models.d override or an
# auto-tune result for one model never leaks into the next.
GLOBAL_CTX_SIZE="$CTX_SIZE"
GLOBAL_N_GPU_LAYERS="$N_GPU_LAYERS"
GLOBAL_CACHE_TYPE_K="$CACHE_TYPE_K"
GLOBAL_CACHE_TYPE_V="$CACHE_TYPE_V"
GLOBAL_FLASH_ATTN="$FLASH_ATTN"
GLOBAL_SPEC_TYPE="$SPEC_TYPE"
GLOBAL_SPEC_DRAFT_N_MAX="$SPEC_DRAFT_N_MAX"

cat > "$CONFIG" <<CFG
healthCheckTimeout: $LOCALAI_HEALTH_CHECK_TIMEOUT
globalTTL: $LOCALAI_GLOBAL_TTL
CFG
chmod 600 "$CONFIG" 2>/dev/null || true

if [ "$ACTIVE_API_KEY_COUNT" -gt 0 ]; then
  {
    echo
    echo "apiKeys:"
    while IFS=$'\t' read -r ACTIVE_NAME ACTIVE_KEY; do
      [ -n "$ACTIVE_KEY" ] || continue
      printf '  # %s\n  - "%s"\n' "$ACTIVE_NAME" "$ACTIVE_KEY"
    done <<<"$ACTIVE_API_KEYS"
  } >> "$CONFIG"
fi

if [ "$METRICS_ENABLED" = "1" ]; then
  cat >> "$CONFIG" <<CFG

performance:
  enable: true
CFG
fi

if [ -n "$PRELOAD_MODELS" ]; then
  {
    echo
    echo "hooks:"
    echo "  on_startup:"
    echo "    preload:"
    for PRELOAD_ID in ${PRELOAD_MODELS//,/ }; do
      printf '      - "%s"\n' "$PRELOAD_ID"
    done
  } >> "$CONFIG"
fi

cat >> "$CONFIG" <<CFG

models:
CFG

MODEL_COUNT=0
while IFS=$'\t' read -r NAME MODEL_REL MODEL; do
  [ -n "$NAME" ] || continue
  case "$NAME$MODEL_REL" in
    *\"*|*"'"*|*'`'*|*\\*)
    echo "Skipping unsupported model path: $MODEL_REL" >&2
    continue
      ;;
  esac

  IS_EMBEDDING=0
  MODEL_EXTRA_ARGS=""
  if [[ "${NAME,,}" == *qwen3*embedding* ]]; then
      MODEL_EXTRA_ARGS="--embeddings --pooling last"
      IS_EMBEDDING=1
  elif model_is_embedding_name "$NAME"; then
      MODEL_EXTRA_ARGS="--embeddings"
      IS_EMBEDDING=1
  fi

  # Reset per-model working values to the global defaults before auto-tune
  # and models.d overrides are applied.
  CTX_SIZE="$GLOBAL_CTX_SIZE"
  N_GPU_LAYERS="$GLOBAL_N_GPU_LAYERS"
  CACHE_TYPE_K="$GLOBAL_CACHE_TYPE_K"
  CACHE_TYPE_V="$GLOBAL_CACHE_TYPE_V"
  FLASH_ATTN="$GLOBAL_FLASH_ATTN"
  SPEC_TYPE="$GLOBAL_SPEC_TYPE"
  SPEC_DRAFT_N_MAX="$GLOBAL_SPEC_DRAFT_N_MAX"
  TTL=""
  ALIASES=""
  MMPROJ=""
  SET_TEMPERATURE=""
  SET_TOP_P=""
  EXTRA_ARGS=""

  if [ "$AUTO_TUNE" = "1" ] && [ "$BACKEND" != "cpu" ]; then
    MODEL_BYTES="$(localai_model_bytes "$MODEL")"
    # AUTO_CTX is intentionally unused here: ctx-size is a user choice about
    # how much context to keep, not a hardware-fit value like the others, so
    # auto-tune leaves the configured CTX_SIZE alone (models.d can still
    # override it per model).
    IFS=$'\t' read -r _AUTO_CTX AUTO_NGL AUTO_FLASH AUTO_CACHE_K AUTO_CACHE_V \
      < <(compute_model_runtime_defaults "$MODEL_BYTES" "$RAM_BYTES" "$VRAM_BYTES" "$BACKEND" "$NGL_AUTO_SUPPORTED")
    [ "$AUTO_NGL" = "-" ] || N_GPU_LAYERS="$AUTO_NGL"
    FLASH_ATTN="$AUTO_FLASH"
    CACHE_TYPE_K="$AUTO_CACHE_K"
    CACHE_TYPE_V="$AUTO_CACHE_V"
  fi

  if [ "$IS_EMBEDDING" -eq 1 ]; then
    TTL="$EMBEDDING_TTL"
    SPEC_TYPE=""
  fi

  # Auto-detect a multimodal projector placed alongside a model kept in its
  # own folder, e.g. models/gemma-4-vision/mmproj-gemma-4.gguf. Only applies
  # to the documented per-model-folder layout; flat top-level models need an
  # explicit MMPROJ= in a models.d override.
  MODEL_DIR_REL="${MODEL_REL%/*}"
  if [ "$MODEL_DIR_REL" != "$MODEL_REL" ]; then
    MMPROJ_CANDIDATE="$(find "$MODELS_DIR/$MODEL_DIR_REL" -maxdepth 1 -type f -iname 'mmproj*.gguf' -print -quit 2>/dev/null || true)"
    if [ -n "$MMPROJ_CANDIDATE" ]; then
      case "$MMPROJ_CANDIDATE" in
        *\"*|*"'"*|*'`'*|*\\*)
          echo "Warning: skipping mmproj file with unsupported path: $MMPROJ_CANDIDATE" >&2
          ;;
        *)
          MMPROJ="$MMPROJ_CANDIDATE"
          ;;
      esac
    fi
  fi

  # Per-model override: conf/models.d/<model-id>.conf. Sourced last so it can
  # override auto-tune, mmproj detection, or any global default for this one
  # model. Uses the same variable names as the global config above, plus
  # TTL, ALIASES, MMPROJ, SET_TEMPERATURE, SET_TOP_P, and EXTRA_ARGS.
  OVERRIDE_FILE="$OVERRIDES_DIR/$NAME.conf"
  if [ -f "$OVERRIDE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$OVERRIDE_FILE"
  fi

  if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || ((CTX_SIZE < 1)); then
    echo "Error: CTX_SIZE for model $NAME must be a positive integer." >&2
    exit 1
  fi
  if ! [[ "$N_GPU_LAYERS" =~ ^([0-9]+|auto|all)$ ]]; then
    echo "Error: N_GPU_LAYERS for model $NAME must be a non-negative integer, 'auto', or 'all'." >&2
    exit 1
  fi
  validate_bool "FLASH_ATTN (model $NAME)" "$FLASH_ATTN"
  validate_spec_type "SPEC_TYPE (model $NAME)" "$SPEC_TYPE"
  validate_optional_positive_integer "SPEC_DRAFT_N_MAX (model $NAME)" "$SPEC_DRAFT_N_MAX"
  validate_optional_nonnegative_integer "TTL (model $NAME)" "$TTL"

  MODEL_SPECIFIC_ARGS=""
  [ "$FLASH_ATTN" = "0" ] || MODEL_SPECIFIC_ARGS="$MODEL_SPECIFIC_ARGS
      --flash-attn on"
  if [ -n "$MMPROJ" ]; then
    MODEL_SPECIFIC_ARGS="$MODEL_SPECIFIC_ARGS
      --mmproj \"$MMPROJ\""
  fi
  if [ -n "$SPEC_TYPE" ] && [ "$SPEC_TYPE" != "none" ]; then
    MODEL_SPECIFIC_ARGS="$MODEL_SPECIFIC_ARGS
      --spec-type $SPEC_TYPE
      --spec-draft-n-max $SPEC_DRAFT_N_MAX"
  fi
  [ -z "$EXTRA_ARGS" ] || MODEL_SPECIFIC_ARGS="$MODEL_SPECIFIC_ARGS
      $EXTRA_ARGS"

  EXTRA_MODEL_YAML=""
  [ -z "$TTL" ] || EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
    ttl: $TTL"

  if [ -n "$ALIASES" ]; then
    EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
    aliases:"
    IFS=',' read -r -a ALIAS_ARRAY <<< "$ALIASES"
    for ALIAS in "${ALIAS_ARRAY[@]}"; do
      ALIAS="$(trim_ws "$ALIAS")"
      [ -n "$ALIAS" ] || continue
      case "$ALIAS" in
        *\"*|*"'"*|*'`'*|*\\*)
          echo "Warning: skipping unsupported alias for model $NAME: $ALIAS" >&2
          continue
          ;;
      esac
      EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
      - \"$ALIAS\""
    done
  fi

  if [ -n "$SET_TEMPERATURE" ] || [ -n "$SET_TOP_P" ]; then
    EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
    filters:
      setParams:"
    [ -z "$SET_TEMPERATURE" ] || EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
        temperature: $SET_TEMPERATURE"
    [ -z "$SET_TOP_P" ] || EXTRA_MODEL_YAML="$EXTRA_MODEL_YAML
        top_p: $SET_TOP_P"
  fi

  MODEL_COUNT=$((MODEL_COUNT + 1))

  cat >> "$CONFIG" <<MODELCFG

  "$NAME":
    proxy: http://$LOCALAI_LISTEN_HOST:\${PORT}
    cmd: >
      "$BIN"
      --port \${PORT}
      --model "$MODEL"
      $MODEL_EXTRA_ARGS
      --n-gpu-layers $N_GPU_LAYERS
      -t $THREADS
      --ctx-size $CTX_SIZE
      --cache-type-k $CACHE_TYPE_K
      --cache-type-v $CACHE_TYPE_V
$MODEL_SPECIFIC_ARGS
$COMMON_EXTRA_ARGS
MODELCFG

  if [ -n "$EXTRA_MODEL_YAML" ]; then
    printf '%s\n' "$EXTRA_MODEL_YAML" >> "$CONFIG"
  fi
  printf '\n' >> "$CONFIG"
done < <(localai_model_entries "$MODELS_DIR")

if [ "$ACTIVE_API_KEY_COUNT" -gt 0 ]; then
  echo "Generated $CONFIG with $MODEL_COUNT model(s) and $ACTIVE_API_KEY_COUNT active API key(s)."
else
  echo "Generated $CONFIG with $MODEL_COUNT model(s)."
fi
