#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_ROOT="$BATS_TEST_TMPDIR/root"
  TEST_AI_DIR="$TEST_ROOT/ai"
  mkdir -p "$TEST_AI_DIR/bin" "$TEST_AI_DIR/models" "$TEST_ROOT/systemd" "$TEST_ROOT/userbin"
  touch "$TEST_AI_DIR/bin/llama-swap" "$TEST_AI_DIR/bin/start.sh"
}

@test "uninstall plan does not claim bin/llama-swap is kept" {
  run bash -c 'printf "n\n" | LOCALAI_DIR="$1" LOCALAI_SYSTEMD_USER_DIR="$2" LOCALAI_USER_BIN_DIR="$3" bash "$4/uninstall-local-ai.sh"' \
    _ "$TEST_AI_DIR" "$TEST_ROOT/systemd" "$TEST_ROOT/userbin" "$REPO_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Will remove:"* ]]
  [[ "$output" == *"$TEST_AI_DIR/bin"* ]]
  [[ "$output" == *"Will keep:"* ]]
  [[ "$output" == *"$TEST_AI_DIR/models"* ]]
  [[ "$output" != *"$TEST_AI_DIR/bin/llama-swap"* ]]
}
