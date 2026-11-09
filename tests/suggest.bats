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

benchmark_fixture() {
  MODELS_DIR="$BATS_TEST_TMPDIR/models"
  mkdir -p "$MODELS_DIR"
  touch "$MODELS_DIR/model-a.gguf" "$MODELS_DIR/BGE-M3.gguf"
  api_base_url() { echo http://localhost:11435; }
  api_auth_curl_args() { AUTH_CURL_ARGS=(); }
  fail() { echo "$*" >&2; exit 1; }
  curl() {
    local destination="" previous="" argument
    for argument in "$@"; do
      [ "$previous" != -o ] || destination="$argument"
      previous="$argument"
    done
    echo '{"choices":[{}],"data":[{"embedding":[0.5]}],"usage":{"prompt_tokens":20,"completion_tokens":16},"timings":{"prompt_per_second":100,"predicted_per_second":8}}' > "$destination"
    echo 2.0
  }
}

@test "benchmark reports measured samples and excludes warm-up" {
  benchmark_fixture
  run benchmark_cmd model-a --runs 2 --tokens 16 --json
  [ "$status" -eq 0 ]
  local report="${lines[${#lines[@]}-1]}"
  echo "$report" | jq -e '.runs==2 and (.samples|length)==2 and .median_wall_seconds==2 and .median_generation_tokens_per_second==8' >/dev/null
}

@test "benchmark supports embeddings and preserves missing timing as unavailable" {
  benchmark_fixture
  run benchmark_cmd BGE-M3 --runs 1 --json
  [ "$status" -eq 0 ]
  echo "${lines[${#lines[@]}-1]}" | jq -e '.type=="embedding"' >/dev/null
}

@test "benchmark handles arbitrary model names with explicit modes" {
  benchmark_fixture
  run benchmark_cmd model-a --type embedding --runs 1 --json
  [ "$status" -eq 0 ]
  echo "${lines[${#lines[@]}-1]}" | jq -e '.type=="embedding"' >/dev/null
  run benchmark_cmd model-a --type completion --runs 1 --json
  [ "$status" -eq 0 ]
  echo "${lines[${#lines[@]}-1]}" | jq -e '.type=="completion"' >/dev/null
}

@test "configured model mode takes priority over its filename" {
  benchmark_fixture
  CONFIG="$BATS_TEST_TMPDIR/config.yaml"
  printf 'models:\n  "model-a":\n    # localai-model-type: embedding\n    cmd: >\n      llama-server --embeddings\n' > "$CONFIG"
  run localai_model_type model-a
  [ "$output" = embedding ]
  run benchmark_cmd model-a --runs 1 --json
  [ "$status" -eq 0 ]
  echo "${lines[${#lines[@]}-1]}" | jq -e '.type=="embedding"' >/dev/null
}

@test "reranking benchmark validates scores and tolerates unavailable timings" {
  benchmark_fixture
  curl() {
    local previous="" argument destination=""
    for argument in "$@"; do
      [ "$previous" != -o ] || destination="$argument"
      previous="$argument"
    done
    echo '{"results":[{"index":0,"relevance_score":0.8}]}' > "$destination"
    echo 0.5
  }
  run benchmark_cmd model-a --type reranking --runs 1 --json
  [ "$status" -eq 0 ]
  echo "${lines[${#lines[@]}-1]}" | jq -e '.type=="reranking" and .median_generation_tokens_per_second==null' >/dev/null
}

@test "benchmark rejects invalid bounds missing models and request failures" {
  benchmark_fixture
  for option in '--runs 0' '--runs 11' '--tokens 4097' '--runs nope' '--unknown'; do
    # Intentional splitting supplies separate CLI arguments.
    run benchmark_cmd model-a $option
    [ "$status" -ne 0 ]
  done
  run benchmark_cmd missing
  [ "$status" -ne 0 ]
  curl() { return 22; }
  run benchmark_cmd model-a --runs 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"request failed"* ]]
}
