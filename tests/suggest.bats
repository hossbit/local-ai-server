#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_AI_DIR="$BATS_TEST_TMPDIR/ai"
  mkdir -p "$TEST_AI_DIR/models"
}

run_suggest() {
  LOCALAI_DIR="$TEST_AI_DIR" \
  LOCALAI_SUGGEST_RAM_BYTES="$((64 * 1024 * 1024 * 1024))" \
  LOCALAI_SUGGEST_VRAM_BYTES="${LOCALAI_SUGGEST_VRAM_BYTES:-0}" \
  LOCALAI_SUGGEST_BACKEND="${LOCALAI_SUGGEST_BACKEND:-cpu}" \
  bash "$REPO_DIR/localai" suggest "$@"
}

@test "suggest keeps CPU backend on CPU-safe cache and no GPU offload" {
  truncate -s 4G "$TEST_AI_DIR/models/tiny.gguf"

  LOCALAI_SUGGEST_BACKEND=cpu \
  LOCALAI_SUGGEST_VRAM_BYTES="$((24 * 1024 * 1024 * 1024))" \
  run run_suggest tiny

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend: cpu"* ]]
  [[ "$output" == *"suggested n-gpu-layers: 0"* ]]
  [[ "$output" == *"suggested flash-attn: 0"* ]]
  [[ "$output" == *"suggested cache types: f16/f16"* ]]
}

@test "suggest recommends full offload when VRAM clearly fits model" {
  truncate -s 4G "$TEST_AI_DIR/models/tiny.gguf"

  LOCALAI_SUGGEST_BACKEND=vulkan \
  LOCALAI_SUGGEST_VRAM_BYTES="$((24 * 1024 * 1024 * 1024))" \
  run run_suggest tiny

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend: vulkan"* ]]
  [[ "$output" == *"detected VRAM: 24.0 GiB"* ]]
  [[ "$output" == *"suggested n-gpu-layers: 999"* ]]
  [[ "$output" == *"suggested flash-attn: 1"* ]]
  [[ "$output" == *"suggested cache types: q8_0/q8_0"* ]]
}

@test "suggest warns when GPU backend has no detectable VRAM" {
  truncate -s 4G "$TEST_AI_DIR/models/tiny.gguf"

  LOCALAI_SUGGEST_BACKEND=rocm \
  LOCALAI_SUGGEST_VRAM_BYTES=0 \
  run run_suggest tiny

  [ "$status" -eq 0 ]
  [[ "$output" == *"backend: rocm"* ]]
  [[ "$output" == *"detected VRAM: unavailable"* ]]
  [[ "$output" == *"warning: GPU backend is selected, but VRAM could not be detected"* ]]
}
