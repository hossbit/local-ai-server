#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  CONF_DIR="$BATS_TEST_TMPDIR/conf"
  LOCALAI_BACKEND_FILE="llama-cpp-backend"
  LOCALAI_DEFAULT_BACKEND="vulkan"
  # shellcheck source=../lib/common.sh
  source "$REPO_DIR/lib/common.sh"
  # shellcheck source=../lib/cli/suggest.sh
  source "$REPO_DIR/lib/cli/suggest.sh"

  unset LOCALAI_SUGGEST_RAM_BYTES LOCALAI_SUGGEST_VRAM_BYTES LOCALAI_SUGGEST_BACKEND LLAMA_CPP_BACKEND
}

@test "system_ram_bytes honors the LOCALAI_SUGGEST_RAM_BYTES override" {
  LOCALAI_SUGGEST_RAM_BYTES=123456
  run system_ram_bytes
  [ "$output" = "123456" ]
}

@test "gpu_vram_bytes honors the LOCALAI_SUGGEST_VRAM_BYTES override" {
  LOCALAI_SUGGEST_VRAM_BYTES=654321
  run gpu_vram_bytes
  [ "$output" = "654321" ]
}

@test "backend_uses_gpu_layers is false only for cpu" {
  run backend_uses_gpu_layers cpu
  [ "$status" -eq 1 ]

  run backend_uses_gpu_layers vulkan
  [ "$status" -eq 0 ]

  run backend_uses_gpu_layers rocm
  [ "$status" -eq 0 ]
}

@test "installed_backend honors the LOCALAI_SUGGEST_BACKEND override" {
  LOCALAI_SUGGEST_BACKEND=rocm
  run installed_backend
  [ "$output" = "rocm" ]
}

@test "installed_backend reads the persisted backend file when present" {
  mkdir -p "$CONF_DIR"
  printf 'cpu' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  run installed_backend
  [ "$output" = "cpu" ]
}

@test "installed_backend falls back to the configured default" {
  run installed_backend
  [ "$output" = "vulkan" ]
}
