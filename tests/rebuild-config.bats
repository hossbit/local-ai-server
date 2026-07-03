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
