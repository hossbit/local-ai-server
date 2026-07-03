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
