#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "llama.cpp version comparison matches tag prefix to binary version" {
  run bash -c 'source "$1"; llama_cpp_versions_match b6099 6099' _ "$REPO_DIR/lib/install.sh"

  [ "$status" -eq 0 ]
}

@test "llama.cpp version comparison still rejects different builds" {
  run bash -c 'source "$1"; llama_cpp_versions_match b6099 6098' _ "$REPO_DIR/lib/install.sh"

  [ "$status" -ne 0 ]
}

@test "release API resolver uses latest endpoint for latest version" {
  run bash -c 'source "$1"; release_api_for_version latest "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/latest" "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"' _ "$REPO_DIR/lib/install.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" ]
}

@test "release API resolver rewrites default latest tag URL for pinned version" {
  run bash -c 'source "$1"; release_api_for_version b9672 "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/latest" "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"' _ "$REPO_DIR/lib/install.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b9672" ]
}
