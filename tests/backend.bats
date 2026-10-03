#!/usr/bin/env bats
#
# lib/cli/backend.sh: `localai backend list` / `localai backend install`.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  # shellcheck source=../lib/cli/backend.sh
  source "$REPO_DIR/lib/cli/backend.sh"

  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  CONF_DIR="$BATS_TEST_TMPDIR/conf"
  LOCALAI_BACKEND_FILE="llama-cpp-backend"
  PID_FILE="$CONF_DIR/llama-swap.pid"
  PID_START_FILE="$CONF_DIR/llama-swap.pid.start"
  mkdir -p "$BIN_DIR" "$CONF_DIR"

  fail() {
    echo "Error: $*" >&2
    exit 1
  }
  llama_cpp_backend_display_version() { echo "version: 10252 (fe2adf0)"; }
  pid_file_matches_process() { return 1; }
}

make_backend_slot() {
  local backend="$1"
  mkdir -p "$BIN_DIR/llama.cpp.d/$backend"
  : > "$BIN_DIR/llama.cpp.d/$backend/llama-server"
  chmod +x "$BIN_DIR/llama.cpp.d/$backend/llama-server"
}

# --- backend_list_cmd ---

@test "backend_list_cmd reports no backends installed when llama.cpp.d is empty" {
  run backend_list_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"No backends installed."* ]]
}

@test "backend_list_cmd lists every installed backend and marks the active one" {
  make_backend_slot vulkan
  make_backend_slot cuda
  printf 'cuda' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"

  run backend_list_cmd
  [ "$status" -eq 0 ]
  # The active row starts with '*', the inactive one doesn't.
  [[ "$output" =~ \*[[:space:]]+cuda ]]
  ! [[ "$output" =~ \*[[:space:]]+vulkan ]]
}

# --- backend_install_cmd ---

@test "backend_install_cmd rejects a missing or extra argument" {
  run backend_install_cmd
  [ "$status" -eq 1 ]

  run backend_install_cmd cuda extra
  [ "$status" -eq 1 ]
}

@test "backend_install_cmd is a no-op when the backend is already installed" {
  make_backend_slot cuda
  update_cmd() { echo "should-not-run"; return 0; }

  run backend_install_cmd cuda
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [[ "$output" != *"should-not-run"* ]]
}

@test "backend_install_cmd installs the requested backend and restores the original active one" {
  make_backend_slot vulkan
  printf 'vulkan' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"

  # Stand-in for the real update flow: simulate it installing cuda and (like
  # the real install_llama_cpp_release_dir) activating it as a side effect.
  update_cmd() {
    make_backend_slot cuda
    echo "cuda" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  activate_llama_cpp_backend() {
    echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  service_cmd() { echo "service $1"; }

  run backend_install_cmd cuda
  [ "$status" -eq 0 ]
  [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ]
  # vulkan was restored as active, not left on the newly-installed cuda.
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "vulkan" ]
  # Service was never reported running, so no restart should have happened.
  [[ "$output" != *"service restart"* ]]
}

@test "backend_install_cmd restarts the service only if it was already running" {
  make_backend_slot vulkan
  printf 'vulkan' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  pid_file_matches_process() { return 0; }

  update_cmd() {
    make_backend_slot cuda
    echo "cuda" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  activate_llama_cpp_backend() {
    echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  service_cmd() { echo "service $1"; }

  run backend_install_cmd cuda
  [ "$status" -eq 0 ]
  [[ "$output" == *"service restart"* ]]
}

@test "backend_install_cmd restores the original backend even when the install fails" {
  make_backend_slot vulkan
  printf 'vulkan' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"

  update_cmd() { return 1; }
  activate_llama_cpp_backend() {
    echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  service_cmd() { :; }

  run backend_install_cmd cuda
  [ "$status" -eq 1 ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "vulkan" ]
}
