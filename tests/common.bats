#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  # shellcheck source=../lib/common.sh
  source "$REPO_DIR/lib/common.sh"
}

# --- expand_path ---

@test "expand_path expands a bare tilde" {
  run expand_path '~'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME" ]
}

@test "expand_path expands a tilde-prefixed path" {
  run expand_path '~/ai/models'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/ai/models" ]
}

@test "expand_path leaves absolute paths unchanged" {
  run expand_path '/opt/ai'
  [ "$output" = "/opt/ai" ]
}

@test "expand_path leaves relative paths unchanged" {
  run expand_path 'ai/models'
  [ "$output" = "ai/models" ]
}

# --- gguf split helpers ---

@test "gguf_split_prefix extracts the model prefix" {
  run gguf_split_prefix 'DeepSeek-V4-Flash-UD-IQ1_M-00001-of-00003.gguf'
  [ "$output" = "DeepSeek-V4-Flash-UD-IQ1_M" ]
}

@test "gguf_split_index and gguf_split_total extract shard numbers" {
  run gguf_split_index 'model-00002-of-00005.gguf'
  [ "$output" = "00002" ]

  run gguf_split_total 'model-00002-of-00005.gguf'
  [ "$output" = "00005" ]
}

@test "gguf_split_prefix is empty for a non-split file" {
  run gguf_split_prefix 'model.gguf'
  [ "$output" = "" ]
}

@test "gguf_split_is_primary is true only for shard 1" {
  run gguf_split_is_primary 'model-00001-of-00003.gguf'
  [ "$status" -eq 0 ]

  run gguf_split_is_primary 'model-00002-of-00003.gguf'
  [ "$status" -eq 1 ]
}

@test "gguf_primary_model_name strips shard suffix for split files" {
  run gguf_primary_model_name 'model-00001-of-00003.gguf'
  [ "$output" = "model" ]
}

@test "gguf_primary_model_name strips .gguf for non-split files" {
  run gguf_primary_model_name 'Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf'
  [ "$output" = "Qwen2.5-Coder-7B-Instruct-Q4_K_M" ]
}

@test "gguf_model_file_is_primary is true for non-split files" {
  run gguf_model_file_is_primary 'model.gguf'
  [ "$status" -eq 0 ]
}

@test "gguf_model_file_is_primary is true only for the first shard" {
  run gguf_model_file_is_primary 'model-00001-of-00003.gguf'
  [ "$status" -eq 0 ]

  run gguf_model_file_is_primary 'model-00003-of-00003.gguf'
  [ "$status" -eq 1 ]
}

@test "gguf_model_file_is_noncanonical_split_fragment accepts canonical split names" {
  run gguf_model_file_is_noncanonical_split_fragment 'model-00001-of-00003.gguf'
  [ "$status" -eq 1 ]
}

@test "gguf_model_file_is_noncanonical_split_fragment accepts a plain model file" {
  run gguf_model_file_is_noncanonical_split_fragment 'model.gguf'
  [ "$status" -eq 1 ]
}

@test "gguf_model_file_is_noncanonical_split_fragment flags dotted of-fragments" {
  run gguf_model_file_is_noncanonical_split_fragment 'model.01.of.03.gguf'
  [ "$status" -eq 0 ]
}

@test "gguf_model_file_is_noncanonical_split_fragment flags part/shard/split fragments" {
  run gguf_model_file_is_noncanonical_split_fragment 'model-part1.gguf'
  [ "$status" -eq 0 ]

  run gguf_model_file_is_noncanonical_split_fragment 'model-shard-2.gguf'
  [ "$status" -eq 0 ]
}

# --- model_is_embedding_name ---

@test "model_is_embedding_name matches common embedding model names" {
  run model_is_embedding_name 'bge-small-en'
  [ "$status" -eq 0 ]

  run model_is_embedding_name 'nomic-embed-text-v1.5'
  [ "$status" -eq 0 ]

  run model_is_embedding_name 'Qwen3-Embedding-4B'
  [ "$status" -eq 0 ]

  run model_is_embedding_name 'multilingual-e5-large'
  [ "$status" -eq 0 ]

  run model_is_embedding_name 'e5-base'
  [ "$status" -eq 0 ]
}

@test "model_is_embedding_name rejects ordinary chat models" {
  run model_is_embedding_name 'Qwen2.5-Coder-7B-Instruct'
  [ "$status" -eq 1 ]

  run model_is_embedding_name 'Mistral-7B-Instruct'
  [ "$status" -eq 1 ]
}

# --- format_bytes_gib ---

@test "format_bytes_gib formats bytes as GiB with one decimal" {
  run format_bytes_gib $((1024 * 1024 * 1024))
  [ "$output" = "1.0 GiB" ]

  run format_bytes_gib 0
  [ "$output" = "0.0 GiB" ]
}

# --- localai_model_entries / localai_has_model_entries / localai_model_bytes ---

setup_models_dir() {
  MODELS_DIR="$BATS_TEST_TMPDIR/models"
  mkdir -p "$MODELS_DIR"
}

@test "localai_model_entries registers a top-level single-file model" {
  setup_models_dir
  : > "$MODELS_DIR/solo.gguf"

  run localai_model_entries "$MODELS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'solo\tsolo.gguf\t'"$MODELS_DIR/solo.gguf"* ]]
}

@test "localai_model_entries uses the folder name for a single split model" {
  setup_models_dir
  mkdir -p "$MODELS_DIR/DeepSeek-V4"
  : > "$MODELS_DIR/DeepSeek-V4/DeepSeek-V4-00001-of-00002.gguf"
  : > "$MODELS_DIR/DeepSeek-V4/DeepSeek-V4-00002-of-00002.gguf"

  run localai_model_entries "$MODELS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'DeepSeek-V4\tDeepSeek-V4/DeepSeek-V4-00001-of-00002.gguf\t'* ]]
  [[ "$output" != *"00002-of-00002"* ]]
}

@test "localai_model_entries skips noncanonical split fragments with a warning" {
  setup_models_dir
  : > "$MODELS_DIR/model.01.of.03.gguf"

  run localai_model_entries "$MODELS_DIR"
  [ "$status" -eq 0 ]
  # No TSV entry (id<TAB>rel<TAB>path) should have been emitted, only the
  # stderr warning that `run` merges into $output.
  [[ "$output" != *$'\t'* ]]
  [[ "$output" == *"does not match canonical llama.cpp split naming"* ]]
}

@test "localai_has_model_entries reflects whether any usable model exists" {
  setup_models_dir
  run localai_has_model_entries "$MODELS_DIR"
  [ "$status" -eq 1 ]

  : > "$MODELS_DIR/solo.gguf"
  run localai_has_model_entries "$MODELS_DIR"
  [ "$status" -eq 0 ]
}

@test "localai_model_bytes sums all shards of a split model" {
  setup_models_dir
  mkdir -p "$MODELS_DIR/split"
  printf 'a' > "$MODELS_DIR/split/model-00001-of-00002.gguf"
  printf 'bb' > "$MODELS_DIR/split/model-00002-of-00002.gguf"

  run localai_model_bytes "$MODELS_DIR/split/model-00001-of-00002.gguf"
  [ "$output" = "3" ]
}
