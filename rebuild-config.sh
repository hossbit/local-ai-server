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

validate_optional_positive_integer() {
  local name="$1"
  local value="$2"

  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < 1)); then
    echo "Error: $name must be a positive integer when set." >&2
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

if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || ((CTX_SIZE < 1)); then
  echo "Error: CTX_SIZE must be a positive integer." >&2
  exit 1
fi

if ! [[ "$N_GPU_LAYERS" =~ ^[0-9]+$ ]]; then
  echo "Error: N_GPU_LAYERS must be a non-negative integer." >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
  echo "Error: THREADS must be a non-negative integer." >&2
  exit 1
fi

validate_optional_positive_integer PARALLEL "$PARALLEL"
validate_optional_positive_integer BATCH_SIZE "$BATCH_SIZE"
validate_optional_positive_integer UBATCH_SIZE "$UBATCH_SIZE"
validate_bool FLASH_ATTN "$FLASH_ATTN"
validate_bool JINJA "$JINJA"
validate_bool MLOCK "$MLOCK"
validate_bool NO_MMAP "$NO_MMAP"

case "$EXTRA_LLAMA_ARGS" in
  *$'\n'*|*$'\r'*)
    echo "Error: EXTRA_LLAMA_ARGS must be a single line." >&2
    exit 1
    ;;
esac

COMMON_EXTRA_ARGS=""
[ -z "$PARALLEL" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --parallel $PARALLEL"
[ -z "$BATCH_SIZE" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --batch-size $BATCH_SIZE"
[ -z "$UBATCH_SIZE" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --ubatch-size $UBATCH_SIZE"
[ "$FLASH_ATTN" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --flash-attn on"
[ "$JINJA" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --jinja"
[ "$MLOCK" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --mlock"
[ "$NO_MMAP" = "0" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      --no-mmap"
[ -z "$EXTRA_LLAMA_ARGS" ] || COMMON_EXTRA_ARGS="$COMMON_EXTRA_ARGS
      $EXTRA_LLAMA_ARGS"

mkdir -p "$CONF_DIR" "$MODELS_DIR"

cat > "$CONFIG" <<CFG
healthCheckTimeout: $LOCALAI_HEALTH_CHECK_TIMEOUT
globalTTL: $LOCALAI_GLOBAL_TTL

models:
CFG

MODEL_COUNT=0
while IFS=$'\t' read -r NAME MODEL_REL MODEL; do
  [ -n "$NAME" ] || continue
  MODEL_EXTRA_ARGS=""
  if [[ "${NAME,,}" == *qwen3*embedding* ]]; then
      MODEL_EXTRA_ARGS="--embeddings --pooling last"
  elif model_is_embedding_name "$NAME"; then
      MODEL_EXTRA_ARGS="--embeddings"
  fi
  case "$NAME$MODEL_REL" in
    *\"*|*"'"*|*'`'*|*\\*)
    echo "Skipping unsupported model path: $MODEL_REL" >&2
    continue
      ;;
  esac
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
$COMMON_EXTRA_ARGS

MODELCFG
done < <(localai_model_entries "$MODELS_DIR")

echo "Generated $CONFIG with $MODEL_COUNT model(s)."
