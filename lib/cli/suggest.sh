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
