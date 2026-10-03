#!/usr/bin/env bats
setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_DIR/lib/cli/models.sh"
  source "$REPO_DIR/lib/cli/service.sh"
  fail() { echo "Error: $*" >&2; exit 1; }
  api_base_url() { echo http://127.0.0.1:11435; }
  api_auth_curl_args() { AUTH_CURL_ARGS=(); }
  require_api_tools() { :; }
  installed_model_exists() { return 0; }
  model_is_embedding_name() { [[ "$1" == *embedding* ]]; }
  api_key_registry_path() { echo "$BATS_TEST_TMPDIR/no-keys"; }
  LOCALAI_HEALTH_CHECK_TIMEOUT=1
}
@test "load all propagates HTTP failure and never prints Loaded" {
  api_models() { echo chat; }
  curl() { return 22; }
  run load_cmd all
  [ "$status" -ne 0 ]
  [[ "$output" != *'Loaded:'* ]]
  [[ "$output" == *'failed to load chat'* ]]
}
@test "embedding load propagates HTTP failure in conditional context" {
  curl() { return 22; }
  if load_one_model embedding > "$BATS_TEST_TMPDIR/out"; then return 1; fi
  ! grep -q Loaded "$BATS_TEST_TMPDIR/out"
}
@test "load all reports listing failure" {
  api_models() { return 1; }
  run load_cmd all
  [ "$status" -ne 0 ]
  [[ "$output" == *'could not list models'* ]]
}
@test "unload all reports unreachable API rather than empty state" {
  running_models() { return 1; }
  run unload_cmd all
  [ "$status" -ne 0 ]
  [[ "$output" != *'No loaded models'* ]]
}
@test "unload all retains empty-state success" {
  running_models() { return 0; }
  run unload_cmd all
  [ "$status" -eq 0 ]
  [[ "$output" == *'No loaded models'* ]]
}
@test "unload HTTP failure is not masked in conditional context" {
  curl() { return 22; }
  if unload_one_model chat > "$BATS_TEST_TMPDIR/out"; then return 1; fi
  ! grep -q Unloaded "$BATS_TEST_TMPDIR/out"
}
@test "check rejects extra arguments before probing API" {
  run check_cmd --chat typo
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}
@test "UI prints URL without opening browser by default" {
  xdg-open() { return 99; }
  run ui_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *'http://127.0.0.1:11435/ui'* ]]
}
@test "UI --open passes encoded model URL as one argument" {
  DISPLAY=:1
  xdg-open() { printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/opened"; }
  run ui_cmd --open 'a model'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/opened")" = 'http://127.0.0.1:11435/upstream/a%20model/' ]
}
@test "UI --open gives useful headless failure with URL" {
  unset DISPLAY WAYLAND_DISPLAY
  run ui_cmd --open
  [ "$status" -ne 0 ]
  [[ "$output" == *'http://127.0.0.1:11435/ui'* ]]
  [[ "$output" == *'no graphical desktop'* ]]
}
@test "UI rejects unknown flags and multiple models" {
  run ui_cmd --bad
  [ "$status" -ne 0 ]
  run ui_cmd one two
  [ "$status" -ne 0 ]
}

@test "UI dashboard shortcuts resolve to upstream routes" {
  run ui_cmd --chat
  [ "$status" -eq 0 ]
  [[ "$output" == *'/ui#/playground'* ]]
  run ui_cmd --logs
  [ "$status" -eq 0 ]
  [[ "$output" == *'/ui#/logs'* ]]
}
@test "UI rejects ambiguous destinations" {
  run ui_cmd --home --chat
  [ "$status" -ne 0 ]
  run ui_cmd --logs chat
  [ "$status" -ne 0 ]
}
@test "launch page escapes model names and keeps keys out" {
  source "$REPO_DIR/lib/common.sh"
  SCRIPT_DIR="$REPO_DIR"
  MODELS_DIR="$BATS_TEST_TMPDIR/models"
  CONF_DIR="$BATS_TEST_TMPDIR/conf"
  mkdir -p "$MODELS_DIR"
  touch "$MODELS_DIR/a & b.gguf" "$MODELS_DIR/text-embedding.gguf"
  run ui_cmd --home
  [ "$status" -eq 0 ]
  grep -q 'a &amp; b' "$CONF_DIR/ui/index.html"
  grep -q 'a%20%26%20b' "$CONF_DIR/ui/index.html"
  ! grep -q 'LOCALAI_MODELS' "$CONF_DIR/ui/index.html"
  ! grep -q 'sk-localai-' "$CONF_DIR/ui/index.html"
  [ "$(stat -c %a "$CONF_DIR/ui/index.html")" = 600 ]
}

@test "UI help is available without model or browser dependencies" {
  run ui_cmd --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: localai ui'* ]]
  [[ "$output" == *'--home'* ]]
  run ui_cmd -h
  [ "$status" -eq 0 ]
}
@test "UI accepts activity and rejects multiple sections" {
  run ui_cmd --activity
  [ "$status" -eq 0 ]
  [[ "$output" == *'/ui#/'* ]]
  run ui_cmd --chat --models
  [ "$status" -ne 0 ]
}

@test "UI explains embedding models and disabled metrics" {
  run ui_cmd text-embedding
  [ "$status" -ne 0 ]
  [[ "$output" == *'embeddings API'* ]]
  LOCALAI_METRICS_ENABLED=0 run ui_cmd --performance
  [ "$status" -eq 0 ]
  [[ "$output" == *'Performance collection is disabled'* ]]
}
