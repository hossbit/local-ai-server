# shellcheck shell=bash disable=SC2154

suggest_for_model() {
  local id="$1"
  local rel="$2"
  local path="$3"
  local model_bytes ram_bytes vram_bytes backend ctx parallel gpu_layers flash cache_k cache_v

  model_bytes="$(localai_model_bytes "$path")"
  ram_bytes="$(system_ram_bytes)"
  vram_bytes="$(gpu_vram_bytes)"
  backend="$(installed_backend)"
  parallel=1

  # Keep defaults conservative: context and KV cache can dominate memory on
  # large models, while model file size is only a rough lower bound.
  IFS=$'\t' read -r ctx gpu_layers flash cache_k cache_v \
    < <(compute_model_runtime_defaults "$model_bytes" "$ram_bytes" "$vram_bytes" "$backend")
  [ "$gpu_layers" != "-" ] || gpu_layers="$LOCALAI_N_GPU_LAYERS"

  echo
  echo "$id"
  echo "  file: $rel"
  echo "  backend: $backend"
  echo "  model size: $(format_bytes_gib "$model_bytes")"
  [ "$ram_bytes" -gt 0 ] && echo "  system RAM: $(format_bytes_gib "$ram_bytes")"
  if backend_uses_gpu_layers "$backend"; then
    if [ "$vram_bytes" -gt 0 ]; then
      echo "  detected VRAM: $(format_bytes_gib "$vram_bytes")"
    else
      echo "  detected VRAM: unavailable"
    fi
  fi
  echo "  suggested ctx-size: $ctx"
  echo "  suggested parallel: $parallel"
  echo "  suggested n-gpu-layers: $gpu_layers"
  echo "  suggested flash-attn: $flash"
  echo "  suggested cache types: $cache_k/$cache_v"
  echo "  configured threads: ${LOCALAI_THREADS:-auto}; benchmark before increasing them"
  echo "  override file: $CONF_DIR/${LOCALAI_MODELS_OVERRIDE_SUBDIR:-models.d}/$id.conf"
  echo "  model mode: $(localai_model_type "$id")"
  if [ "$(localai_model_type "$id")" = embedding ]; then
    echo "  embedding advice: keep inputs within the model context and microbatch; adjust chunk size and UBATCH_SIZE to available memory."
  else
    echo "  context advice: choose a context supported by the model; longer prompts increase latency and memory use."
  fi
  if backend_uses_gpu_layers "$backend" && [ "$vram_bytes" -gt 0 ] && [ "$model_bytes" -gt "$vram_bytes" ]; then
    echo "  placement: partial GPU offload with CPU/RAM; the complete model cannot fit in detected VRAM."
  fi
  echo "  measure current settings: localai suggest --benchmark '$id'"

  if [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 85 / 100)) ]; then
    echo "  warning: model files are close to or larger than available RAM; expect failure or unusable speed."
  elif [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 60 / 100)) ]; then
    echo "  warning: large model for this machine; keep context and parallel low."
  fi
  if backend_uses_gpu_layers "$backend" && [ "$vram_bytes" -eq 0 ]; then
    echo "  note: VRAM could not be detected here, but n-gpu-layers auto lets llama-server fit layers to free device memory at load time regardless."
  fi
}

suggest_cmd() {
  if [ "${1:-}" = "--benchmark" ]; then
    shift
    benchmark_cmd "$@"
    return $?
  fi
  if [ "${1:-}" = "--help" ]; then
    echo "Usage: localai suggest [MODEL]"
    echo "       localai suggest --benchmark MODEL [--type auto|chat|completion|embedding|reranking]"
    echo "               [--runs 1..10] [--tokens 1..4096] [--prompt-file FILE] [--json]"
    echo "Benchmarks the running service with one warm-up and repeated requests."
    echo "Loads the selected model; settings remain unchanged. Use --prompt-file for your own text workload."
    return 0
  fi
  local target="${1:-}" id rel path matched=0 DETECTED_GPU_COUNT

  [ "$#" -le 1 ] || fail "usage: localai suggest [MODEL]"
  if [ ! -d "$MODELS_DIR" ]; then
    echo "Models directory does not exist: $MODELS_DIR"
    return 0
  fi

  echo "Runtime suggestions are advisory; memory checks use actual GGUF file size plus rough RAM/VRAM heuristics, not an exact parameter-count formula."
  echo "Set overrides with LOCALAI_CTX_SIZE, LOCALAI_N_GPU_LAYERS, LOCALAI_PARALLEL, and related variables."
  DETECTED_GPU_COUNT="$(gpu_count)"
  if [ "$DETECTED_GPU_COUNT" -gt 1 ]; then
    echo "Detected $DETECTED_GPU_COUNT GPUs. Tune placement with LOCALAI_SPLIT_MODE (none/layer/tensor), LOCALAI_TENSOR_SPLIT, LOCALAI_MAIN_GPU, and LOCALAI_DEVICE."
  fi
  while IFS=$'\t' read -r id rel path; do
    [ -n "$id" ] || continue
    if [ -n "$target" ] && [ "$id" != "$target" ] && [ "${rel%.gguf}" != "$target" ]; then
      continue
    fi
    matched=1
    suggest_for_model "$id" "$rel" "$path"
  done < <(localai_model_entries "$MODELS_DIR")

  if [ "$matched" -eq 0 ]; then
    if [ -n "$target" ]; then
      fail "model not found: $target"
    fi
    echo "No GGUF models found in $MODELS_DIR"
  fi
}

# Measure the installed server rather than estimating speed from model size.
# A separate warm-up excludes model loading; wall time and engine timings
# remain distinct because HTTP overhead is not token generation time.
benchmark_cmd() (
  local model="${1:-}" runs=3 tokens=128 json=0 value result payload elapsed metrics type=auto prompt_file=""
  local endpoint prompt="Write a detailed numbered list of practical tips for testing software. Keep going until you have at least twenty tips."
  local run_index tmp samples summary embedding=0 backend
  [ -n "$model" ] || fail "usage: localai suggest --benchmark MODEL [--runs N] [--tokens N] [--json]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runs|--tokens)
        [ "$#" -ge 2 ] || fail "missing value for $1"
        value="$2"
        if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 4 ]; then
          fail "invalid value for $1"
        fi
        value=$((10#$value))
        [ "$value" -ge 1 ] || fail "$1 must be positive"
        if [ "$1" = --runs ]; then
          [ "$value" -le 10 ] || fail "--runs must be at most 10"
          runs="$value"
        else
          [ "$value" -le 4096 ] || fail "--tokens must be at most 4096"
          tokens="$value"
        fi
        shift 2 ;;
      --json) json=1; shift ;;
      --type)
        [ "$#" -ge 2 ] || fail "missing value for --type"
        case "$2" in auto|chat|completion|embedding|reranking) type="$2" ;; *) fail "invalid benchmark type: $2" ;; esac
        shift 2 ;;
      --prompt-file)
        if [ "$#" -lt 2 ] || [ ! -f "$2" ] || [ ! -r "$2" ]; then
          fail "--prompt-file needs a readable file"
        fi
        prompt_file="$2"; shift 2 ;;
      *) fail "unknown benchmark option: $1" ;;
    esac
  done
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    fail "curl and jq are required for benchmarking"
  fi
  local id rel path canonical=""
  while IFS=$'\t' read -r id rel path; do
    if [ "$model" = "$id" ] || [ "$model" = "${rel%.gguf}" ]; then canonical="$id"; break; fi
  done < <(localai_model_entries "$MODELS_DIR")
  [ -n "$canonical" ] || fail "model not found: $model"
  model="$canonical"
  [ "$type" != auto ] || type="$(localai_model_type "$model")"
  [ "$type" != embedding ] || embedding=1
  if [ -n "$prompt_file" ]; then prompt="$(<"$prompt_file")"; fi
  backend="$(installed_backend)"
  tmp="$(mktemp -d)" || exit 1
  trap 'rm -rf -- "$tmp"' EXIT
  samples="$tmp/samples.jsonl"
  : > "$samples"
  if [ "$embedding" -eq 1 ]; then
    [ -n "$prompt_file" ] || prompt="Local search benchmark input."
    endpoint=embeddings
    payload="$(jq -nc --arg model "$model" --arg prompt "$prompt" '{model:$model,input:$prompt}')"
  elif [ "$type" = reranking ]; then
    endpoint=rerank
    payload="$(jq -nc --arg model "$model" --arg prompt "$prompt" '{model:$model,query:"software testing",documents:[$prompt,"A recipe for bread."],top_n:2}')"
  elif [ "$type" = completion ]; then
    endpoint=completions
    payload="$(jq -nc --arg model "$model" --arg prompt "$prompt" --argjson tokens "$tokens" '{model:$model,prompt:$prompt,max_tokens:$tokens,temperature:0,seed:42,cache_prompt:false}')"
  else
    endpoint=chat/completions
    payload="$(jq -nc --arg model "$model" --arg prompt "$prompt" --argjson tokens "$tokens" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:$tokens,temperature:0,seed:42,cache_prompt:false}')"
  fi
  api_auth_curl_args
  echo "Benchmarking $model on $backend: warm-up plus $runs measured request(s). This can unload another model." >&2
  for ((run_index=0; run_index<=runs; run_index++)); do
    result="$tmp/response.json"
    if ! elapsed="$(curl "${AUTH_CURL_ARGS[@]}" --connect-timeout 10 --max-time 600 -fsS \
      -H 'Content-Type: application/json' --data "$payload" -o "$result" -w '%{time_total}' \
      "$(api_base_url)/v1/$endpoint")"; then
      fail "benchmark request failed; check localai logs"
    fi
    if [ "$embedding" -eq 1 ]; then
      jq -e '.data | length > 0' "$result" >/dev/null || fail "invalid embedding response"
    elif [ "$type" = reranking ]; then
      jq -e '(.results // .data) | length > 0' "$result" >/dev/null || fail "invalid reranking response"
    else
      jq -e '(.usage.completion_tokens // 0) > 0 and (.choices | length > 0)' "$result" >/dev/null || fail "invalid chat response"
    fi
    [ "$run_index" -gt 0 ] || continue
    metrics="$(jq -c --argjson seconds "$elapsed" --argjson run "$run_index" '{run:$run,wall_seconds:$seconds,prompt_tokens:(.usage.prompt_tokens // null),completion_tokens:(.usage.completion_tokens // null),prompt_tokens_per_second:(.timings.prompt_per_second // null),generation_tokens_per_second:(.timings.predicted_per_second // null)}' "$result")"
    printf '%s\n' "$metrics" >> "$samples"
    echo "  request $run_index/$runs: ${elapsed}s" >&2
  done
  summary="$(jq -sc --arg model "$model" --arg backend "$backend" --arg type "$type" '
    def median: sort | if length == 0 then null else . as $a | length as $n | if $n % 2 == 1 then $a[($n/2|floor)] else ($a[$n/2-1]+$a[$n/2])/2 end end;
    {model:$model,backend:$backend,type:$type,runs:length,median_wall_seconds:(map(.wall_seconds)|median),median_generation_tokens_per_second:(map(.generation_tokens_per_second)|map(select(. != null))|median),median_prompt_tokens_per_second:(map(.prompt_tokens_per_second)|map(select(. != null))|median),samples:.}' "$samples")"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$summary"
  else
    jq -r '"Model: \(.model) (\(.backend), \(.type))\nMeasured requests: \(.runs)\nMedian request time: \(.median_wall_seconds) seconds\nMedian generation: \(.median_generation_tokens_per_second // "unavailable") tokens/s\nMedian prompt processing: \(.median_prompt_tokens_per_second // "unavailable") tokens/s"' <<< "$summary"
    echo "Compare identical workloads and settings. This is a short speed test, not a model quality or maximum-context test."
  fi
)
