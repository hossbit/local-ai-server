#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_AI_DIR="$BATS_TEST_TMPDIR/ai"
  mkdir -p "$TEST_AI_DIR/models"
}

run_rebuild() {
  LOCALAI_DIR="$TEST_AI_DIR" \
  LLAMA_CPP_BACKEND=cpu \
  bash "$REPO_DIR/rebuild-config.sh"
}

@test "rebuild-config writes chat model without embeddings flag" {
  touch "$TEST_AI_DIR/models/granite-3.3.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  ! grep -q -- '--embeddings' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config marks known embedding model families" {
  touch "$TEST_AI_DIR/models/bge-small-en.gguf"
  touch "$TEST_AI_DIR/models/multilingual-e5-large.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--embeddings' "$TEST_AI_DIR/conf/config.yaml")" -eq 2 ]
}

@test "rebuild-config does not treat every e5 substring as embeddings" {
  touch "$TEST_AI_DIR/models/base5-chat.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  ! grep -q -- '--embeddings' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config preserves qwen3 embedding pooling" {
  touch "$TEST_AI_DIR/models/qwen3-embedding.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  grep -q -- '--embeddings --pooling last' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config registers only first shard for flat split GGUF" {
  touch "$TEST_AI_DIR/models/DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf"
  touch "$TEST_AI_DIR/models/DeepSeek-V4-Flash-UD-IQ1_M-00002-of-00003.gguf"
  touch "$TEST_AI_DIR/models/DeepSeek-V4-Flash-UD-IQ1_M-00003-of-00003.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  grep -q -- '"DeepSeek-V4-Flash-UD-IQ1_M":' "$TEST_AI_DIR/conf/config.yaml"
  grep -q -- '--model "'"$TEST_AI_DIR"'/models/DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf"' "$TEST_AI_DIR/conf/config.yaml"
  ! grep -q -- '00002-of-00003' "$TEST_AI_DIR/conf/config.yaml"
  ! grep -q -- '00003-of-00003' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config supports one folder per split GGUF model" {
  mkdir -p "$TEST_AI_DIR/models/deepseek-v4-flash"
  touch "$TEST_AI_DIR/models/deepseek-v4-flash/DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf"
  touch "$TEST_AI_DIR/models/deepseek-v4-flash/DeepSeek-V4-Flash-UD-IQ1_M-00002-of-00003.gguf"
  touch "$TEST_AI_DIR/models/deepseek-v4-flash/DeepSeek-V4-Flash-UD-IQ1_M-00003-of-00003.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  grep -q -- '"deepseek-v4-flash":' "$TEST_AI_DIR/conf/config.yaml"
  grep -q -- '--model "'"$TEST_AI_DIR"'/models/deepseek-v4-flash/DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf"' "$TEST_AI_DIR/conf/config.yaml"
  ! grep -q -- '00002-of-00003' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config warns when split shard is missing" {
  touch "$TEST_AI_DIR/models/model-00001-of-00003.gguf"
  touch "$TEST_AI_DIR/models/model-00003-of-00003.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  [[ "$output" == *"missing shard"* ]]
  [[ "$output" == *"model-00002-of-00003.gguf"* ]]
}

@test "rebuild-config skips non-canonical split-looking fragments with fix warning" {
  touch "$TEST_AI_DIR/models/model-part1.gguf"
  touch "$TEST_AI_DIR/models/model-part2.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  [[ "$output" == *"looks like a split GGUF fragment"* ]]
  [[ "$output" == *"llama-gguf-split --merge"* ]]
  [[ "$output" == *"Generated $TEST_AI_DIR/conf/config.yaml with 0 model(s)."* ]]
  ! grep -q -- '"model-part1":' "$TEST_AI_DIR/conf/config.yaml"
  ! grep -q -- '"model-part2":' "$TEST_AI_DIR/conf/config.yaml"
}

@test "rebuild-config does not treat ordinary of names as split fragments" {
  touch "$TEST_AI_DIR/models/wizard-of-oz.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  grep -q -- '"wizard-of-oz":' "$TEST_AI_DIR/conf/config.yaml"
  [[ "$output" != *"looks like a split GGUF fragment"* ]]
}

@test "rebuild-config does not treat real model names with long numbers as split fragments" {
  touch "$TEST_AI_DIR/models/OLMo-2-1124-13B-Instruct-Q4_K_M.gguf"
  touch "$TEST_AI_DIR/models/model-2024-release.gguf"

  run run_rebuild

  [ "$status" -eq 0 ]
  grep -q -- '"OLMo-2-1124-13B-Instruct-Q4_K_M":' "$TEST_AI_DIR/conf/config.yaml"
  grep -q -- '"model-2024-release":' "$TEST_AI_DIR/conf/config.yaml"
  [[ "$output" != *"looks like a split GGUF fragment"* ]]
}
