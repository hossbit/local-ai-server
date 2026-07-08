# shellcheck shell=bash disable=SC2154

system_ram_bytes() {
  if [ -n "${LOCALAI_SUGGEST_RAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_RAM_BYTES"
    return 0
  fi

  awk '/MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || printf '0\n'
}

gpu_vram_bytes() {
  local mib bytes candidate max_bytes=0

  if [ -n "${LOCALAI_SUGGEST_VRAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_VRAM_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk 'NR == 1 {print int($1); exit}')"
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi

  if command -v rocm-smi >/dev/null 2>&1; then
    bytes="$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total Memory.*\(B\)/ {print int($NF); exit}')"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$bytes"
      return 0
    fi
  fi

  for candidate in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -r "$candidate" ] || continue
    bytes="$(cat "$candidate" 2>/dev/null || printf '0')"
    if [ -n "$bytes" ] && [ "$bytes" -gt "$max_bytes" ] 2>/dev/null; then
      max_bytes="$bytes"
    fi
  done
  if [ "$max_bytes" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$max_bytes"
    return 0
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    mib="$(vulkaninfo 2>/dev/null | awk '
      /heap [0-9]+:/ && /size =/ {
        value = $0
        sub(/^.*size = /, "", value)
        split(value, parts, " ")
        amount = parts[1] + 0
        unit = parts[2]
        if (unit ~ /GiB/) amount *= 1024
        if (unit ~ /KiB/) amount /= 1024
        if (amount > max) max = amount
      }
      END { if (max > 0) print int(max) }
    ')"
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi

  printf '0\n'
}

installed_backend() {
  if [ -n "${LOCALAI_SUGGEST_BACKEND:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_BACKEND"
  elif [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ]; then
    cat "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  else
    printf '%s\n' "${LLAMA_CPP_BACKEND:-$LOCALAI_DEFAULT_BACKEND}"
  fi
}

backend_uses_gpu_layers() {
  case "$1" in
    cpu) return 1 ;;
    *) return 0 ;;
  esac
}

suggest_for_model() {
  local id="$1"
  local rel="$2"
  local path="$3"
  local model_bytes ram_bytes vram_bytes backend ctx parallel gpu_layers flash cache_k cache_v

  model_bytes="$(localai_model_bytes "$path")"
  ram_bytes="$(system_ram_bytes)"
  vram_bytes="$(gpu_vram_bytes)"
  backend="$(installed_backend)"

  ctx=8192
  parallel=1
  gpu_layers=0
  flash=0
  cache_k=f16
  cache_v=f16

  # Keep defaults conservative: context and KV cache can dominate memory on
  # large models, while model file size is only a rough lower bound.
  if [ "$ram_bytes" -ge $((96 * 1024 * 1024 * 1024)) ]; then
    ctx=16384
  fi
  if [ "$model_bytes" -ge $((80 * 1024 * 1024 * 1024)) ]; then
    ctx=4096
  fi

  if backend_uses_gpu_layers "$backend"; then
    flash=1
    cache_k=q8_0
    cache_v=q8_0

    if [ "$vram_bytes" -gt 0 ] && [ "$model_bytes" -gt 0 ] && [ "$vram_bytes" -ge $((model_bytes * 6 / 5)) ]; then
      gpu_layers=999
    elif [ "$vram_bytes" -ge $((16 * 1024 * 1024 * 1024)) ]; then
      gpu_layers=32
    elif [ "$vram_bytes" -ge $((8 * 1024 * 1024 * 1024)) ]; then
      gpu_layers=16
    elif [ "$vram_bytes" -ge $((4 * 1024 * 1024 * 1024)) ]; then
      gpu_layers=8
    else
      gpu_layers="$LOCALAI_N_GPU_LAYERS"
    fi
  fi

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

  if [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 85 / 100)) ]; then
    echo "  warning: model files are close to or larger than available RAM; expect failure or unusable speed."
  elif [ "$ram_bytes" -gt 0 ] && [ "$model_bytes" -gt $((ram_bytes * 60 / 100)) ]; then
    echo "  warning: large model for this machine; keep context and parallel low."
  fi
  if backend_uses_gpu_layers "$backend" && [ "$vram_bytes" -eq 0 ]; then
    echo "  warning: GPU backend is selected, but VRAM could not be detected; n-gpu-layers uses the configured default."
  fi
}

suggest_cmd() {
  local target="${1:-}" id rel path matched=0

  [ "$#" -le 1 ] || fail "usage: localai suggest [MODEL]"
  if [ ! -d "$MODELS_DIR" ]; then
    echo "Models directory does not exist: $MODELS_DIR"
    return 0
  fi

  echo "Runtime suggestions are advisory; memory checks use actual GGUF file size plus rough RAM/VRAM heuristics, not an exact parameter-count formula."
  echo "Set overrides with LOCALAI_CTX_SIZE, LOCALAI_N_GPU_LAYERS, LOCALAI_PARALLEL, and related variables."
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
