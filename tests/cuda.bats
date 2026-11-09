#!/usr/bin/env bats
#
# Mocks nvidia-smi/nvcc/git/cmake via PATH shims in $BATS_TEST_TMPDIR/bin,
# since (unlike lib/common.sh's LOCALAI_SUGGEST_* overrides) lib/cuda.sh calls
# these external commands directly by name.

bats_require_minimum_version 1.5.0

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  PATH="$MOCK_BIN:$PATH"

  # shellcheck source=../lib/cuda.sh
  source "$REPO_DIR/lib/cuda.sh"

  log() { :; }
  fail() {
    echo "Error: $*" >&2
    exit 1
  }

  unset LOCALAI_NVCC LOCALAI_CUDA_ARCHITECTURES LOCALAI_CUDA_FALLBACK

  # Default-deny stubs for every external command these tests care about, so
  # results are hermetic regardless of whether the machine actually running
  # bats has a real NVIDIA GPU/driver/toolkit installed (this one does).
  # Individual tests override any of these with mock_bin as needed.
  local cmd
  for cmd in nvidia-smi nvcc vulkaninfo; do
    mock_bin "$cmd" 'exit 1'
  done
  mock_bin ldconfig 'exit 0'
}

mock_bin() {
  local name="$1" body="$2"
  cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$MOCK_BIN/$name"
}

# --- cuda_has_working_driver ---

@test "cuda_has_working_driver succeeds when nvidia-smi lists a GPU" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050 Laptop GPU"'
  run cuda_has_working_driver
  [ "$status" -eq 0 ]
}

@test "cuda_has_working_driver fails when nvidia-smi is absent" {
  run cuda_has_working_driver
  [ "$status" -eq 1 ]
}

@test "cuda_has_working_driver fails when nvidia-smi returns no GPU name" {
  mock_bin nvidia-smi 'exit 0'
  run cuda_has_working_driver
  [ "$status" -eq 1 ]
}

# --- cuda_find_nvcc ---

@test "cuda_find_nvcc finds nvcc on PATH" {
  mock_bin nvcc 'echo "nvcc: NVIDIA (R) Cuda compiler driver"'
  run cuda_find_nvcc
  [ "$status" -eq 0 ]
  [ "$output" = "$MOCK_BIN/nvcc" ]
}

@test "cuda_find_nvcc fails when nvcc is nowhere to be found" {
  run cuda_find_nvcc
  [ "$status" -eq 1 ]
}

@test "LOCALAI_NVCC takes precedence over PATH" {
  mock_bin nvcc 'echo "wrong one"'
  mkdir -p "$BATS_TEST_TMPDIR/alt"
  cat > "$BATS_TEST_TMPDIR/alt/nvcc" <<'EOF'
#!/usr/bin/env bash
echo "right one"
EOF
  chmod +x "$BATS_TEST_TMPDIR/alt/nvcc"

  LOCALAI_NVCC="$BATS_TEST_TMPDIR/alt/nvcc"
  run cuda_find_nvcc
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/alt/nvcc" ]
}

@test "LOCALAI_NVCC fails outright when it doesn't run, without falling back to PATH" {
  mock_bin nvcc 'echo "should not be used"'
  LOCALAI_NVCC="/nonexistent/nvcc"
  run cuda_find_nvcc
  [ "$status" -eq 1 ]
}

# --- cuda_toolkit_version ---

@test "cuda_toolkit_version parses the release line" {
  mock_bin nvcc 'echo "Cuda compilation tools, release 12.4, V12.4.131"'
  run cuda_toolkit_version "$MOCK_BIN/nvcc"
  [ "$output" = "12.4" ]
}

# --- cuda_detect_architectures ---

@test "compute capability 8.6 converts to 86" {
  mock_bin nvidia-smi 'echo "8.6"'
  run cuda_detect_architectures
  [ "$status" -eq 0 ]
  [ "$output" = "86" ]
}

@test "multiple compute capabilities are deduplicated and sorted into a semicolon list" {
  mock_bin nvidia-smi 'printf "8.6\n7.5\n8.6\n8.9\n"'
  run cuda_detect_architectures
  [ "$status" -eq 0 ]
  [ "$output" = "75;86;89" ]
}

@test "cuda_detect_architectures fails when nvidia-smi reports nothing" {
  mock_bin nvidia-smi 'exit 0'
  run cuda_detect_architectures
  [ "$status" -eq 1 ]
}

# --- cuda_validate_architectures / cuda_resolve_architectures ---

@test "cuda_validate_architectures accepts the auto/native/all-major keywords" {
  run cuda_validate_architectures auto
  [ "$status" -eq 0 ]
  run cuda_validate_architectures native
  [ "$status" -eq 0 ]
  run cuda_validate_architectures all-major
  [ "$status" -eq 0 ]
}

@test "cuda_validate_architectures accepts a semicolon-separated numeric list" {
  run cuda_validate_architectures "75;80;86;89"
  [ "$status" -eq 0 ]
}

@test "cuda_validate_architectures rejects malformed input" {
  run cuda_validate_architectures "8.6"
  [ "$status" -eq 1 ]
  run cuda_validate_architectures "86; rm -rf /"
  [ "$status" -eq 1 ]
  run cuda_validate_architectures '$(whoami)'
  [ "$status" -eq 1 ]
  run cuda_validate_architectures ""
  [ "$status" -eq 1 ]
}

@test "cuda_resolve_architectures passes explicit values through unchanged" {
  run cuda_resolve_architectures "86"
  [ "$status" -eq 0 ]
  [ "$output" = "86" ]
}

@test "cuda_resolve_architectures rejects an invalid explicit value before touching CMake" {
  run cuda_resolve_architectures "not-a-value"
  [ "$status" -eq 1 ]
}

@test "cuda_resolve_architectures auto detects from nvidia-smi" {
  mock_bin nvidia-smi 'echo "8.6"'
  run cuda_resolve_architectures "auto"
  [ "$status" -eq 0 ]
  [ "$output" = "86" ]
}

# --- vulkan_is_usable ---

@test "vulkan_is_usable succeeds when vulkaninfo reports a summary" {
  mock_bin vulkaninfo 'exit 0'
  run vulkan_is_usable
  [ "$status" -eq 0 ]
}

@test "vulkan_is_usable fails when neither vulkaninfo nor the loader is present" {
  mock_bin ldconfig 'exit 1'
  run vulkan_is_usable
  [ "$status" -eq 1 ]
}

# --- cuda_resolve_auto_backend ---

@test "auto selects cuda when driver and nvcc are both usable" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  mock_bin nvcc 'echo "release 12.4"'
  run cuda_resolve_auto_backend
  [ "$status" -eq 0 ]
  [ "$output" = "cuda" ]
}

@test "auto falls back to vulkan when the GPU exists but nvcc is absent" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  mock_bin vulkaninfo 'exit 0'
  run cuda_resolve_auto_backend
  [ "$status" -eq 0 ]
  [ "$output" = "vulkan" ]
}

@test "auto falls back to cpu when neither CUDA nor Vulkan is usable" {
  run cuda_resolve_auto_backend
  [ "$status" -eq 0 ]
  [ "$output" = "cpu" ]
}

# --- cuda_resolve_explicit_backend ---

@test "explicit cuda fails clearly when no NVIDIA GPU exists" {
  LOCALAI_CUDA_FALLBACK=0
  run cuda_resolve_explicit_backend
  [ "$status" -eq 1 ]
  [[ "$output" == *"nvidia-smi"* || "$output" == *"NVIDIA"* ]]
}

@test "explicit cuda fails clearly when nvcc is missing" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  LOCALAI_CUDA_FALLBACK=0
  run cuda_resolve_explicit_backend
  [ "$status" -eq 1 ]
  [[ "$output" == *"nvcc"* ]]
}

@test "explicit cuda fails clearly by default (LOCALAI_CUDA_FALLBACK unset), never silently substitutes another backend" {
  # Reproduces a real bug: an explicit `localai backend install cuda` (or
  # LLAMA_CPP_BACKEND=cuda) request silently installed vulkan instead when
  # nvcc was missing, printing only a warning -- because
  # LOCALAI_CUDA_FALLBACK defaulted to 1 even though this function's own
  # comment already documented explicit cuda as "strict by default". Only
  # `auto` (cuda_resolve_auto_backend) should ever choose a different
  # backend on its own; an explicit request must succeed at that exact
  # backend or fail with an actionable error.
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  mock_bin vulkaninfo 'exit 0'
  unset LOCALAI_CUDA_FALLBACK

  # --separate-stderr: the error message legitimately *mentions* vulkan now
  # (as one of several suggested alternatives the user could choose
  # themselves), which is fine -- what must never happen is the function's
  # own return value (stdout, what a caller would actually install) being
  # vulkan instead of the cuda that was explicitly requested.
  run --separate-stderr cuda_resolve_explicit_backend
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"nvcc"* ]]
}

# --- cuda_toolkit_install_hint: never installs the CUDA Toolkit
# automatically, but points at the right next step for the actual package
# manager on this system rather than a one-size-fits-all message.

@test "cuda_toolkit_install_hint suggests apt-get on an apt system" {
  mock_bin apt-get 'exit 0'
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_toolkit_install_hint
  PATH="$real_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"apt-get install nvidia-cuda-toolkit"* ]]
}

@test "cuda_toolkit_install_hint points at NVIDIA's own repo on a dnf/yum system" {
  mock_bin dnf 'exit 0'
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_toolkit_install_hint
  PATH="$real_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Fedora/RHEL"* ]]
  [[ "$output" == *"developer.nvidia.com/cuda-downloads"* ]]
}

@test "cuda_toolkit_install_hint falls back to a generic link with no known package manager" {
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_toolkit_install_hint
  PATH="$real_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"developer.nvidia.com/cuda-downloads"* ]]
}

# --- cuda_require_build_tools / cuda_build_tools_install_hint: unlike the
# CUDA Toolkit, ordinary build tooling (compiler, cmake, git) is safe to name
# a direct install command for, so a missing one must fail with that command
# rather than a bare "install it and retry".

@test "cuda_build_tools_install_hint suggests apt-get on an apt system" {
  mock_bin apt-get 'exit 0'
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_build_tools_install_hint
  PATH="$real_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"apt-get install"* ]]
  [[ "$output" == *"cmake"* ]]
  [[ "$output" == *"git"* ]]
}

@test "cuda_build_tools_install_hint suggests dnf on a dnf system" {
  mock_bin dnf 'exit 0'
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_build_tools_install_hint
  PATH="$real_path"

  [ "$status" -eq 0 ]
  [[ "$output" == *"dnf install"* ]]
  [[ "$output" == *"cmake"* ]]
}

@test "cuda_require_build_tools passes when git and cmake are both present" {
  mock_bin git 'exit 0'
  mock_bin cmake 'exit 0'

  run cuda_require_build_tools
  [ "$status" -eq 0 ]
}

@test "cuda_require_build_tools fails with an actionable install command when cmake is missing" {
  mock_bin git 'exit 0'
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_require_build_tools
  PATH="$real_path"

  [ "$status" -ne 0 ]
  [[ "$output" == *"cmake"* ]]
  [[ "$output" == *"Fix:"* ]]
}

@test "cuda_require_build_tools reports every missing tool, not just the first" {
  local real_path="$PATH"
  PATH="$MOCK_BIN"

  run cuda_require_build_tools
  PATH="$real_path"

  [ "$status" -ne 0 ]
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"cmake"* ]]
}

@test "explicit cuda falls back to vulkan when fallback is enabled and vulkan is usable" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  mock_bin vulkaninfo 'exit 0'
  LOCALAI_CUDA_FALLBACK=1
  run --separate-stderr cuda_resolve_explicit_backend
  [ "$status" -eq 0 ]
  [ "$output" = "vulkan" ]
  [[ "$stderr" == *"Warning"* ]]
}

@test "explicit cuda succeeds when driver and nvcc are both usable" {
  mock_bin nvidia-smi 'echo "NVIDIA GeForce RTX 3050"'
  mock_bin nvcc 'echo "release 12.4"'
  run --separate-stderr cuda_resolve_explicit_backend
  [ "$status" -eq 0 ]
  [ "$output" = "cuda" ]
}

# --- cuda_build_cache_key / cuda_build_cache_matches ---

@test "cuda_build_cache_matches ignores the built_at line" {
  mock_bin nvcc 'echo "release 12.4"'
  local key meta
  key="$(cuda_build_cache_key "b1234" "$MOCK_BIN/nvcc" "86")"
  meta="$BATS_TEST_TMPDIR/meta"
  {
    printf '%s\n' "$key"
    printf 'built_at=2026-01-01T00:00:00Z\n'
  } > "$meta"

  run cuda_build_cache_matches "$meta" "$key"
  [ "$status" -eq 0 ]
}

@test "cuda_build_cache_matches rejects a changed revision or architecture list" {
  mock_bin nvcc 'echo "release 12.4"'
  local meta
  meta="$BATS_TEST_TMPDIR/meta"
  cuda_build_cache_key "b1234" "$MOCK_BIN/nvcc" "86" > "$meta"

  run cuda_build_cache_matches "$meta" "$(cuda_build_cache_key "b5678" "$MOCK_BIN/nvcc" "86")"
  [ "$status" -eq 1 ]
  run cuda_build_cache_matches "$meta" "$(cuda_build_cache_key "b1234" "$MOCK_BIN/nvcc" "89")"
  [ "$status" -eq 1 ]
}

# --- cuda_installed_revision ---

@test "cuda_installed_revision reads the recorded revision when the cuda slot has a binary" {
  BIN_DIR="$BATS_TEST_TMPDIR/bin1"
  CONF_DIR="$BATS_TEST_TMPDIR/conf1"
  LOCALAI_CUDA_META_FILE="llama-cpp-cuda-meta"
  mkdir -p "$BIN_DIR/llama.cpp.d/cuda" "$CONF_DIR"
  : > "$BIN_DIR/llama.cpp.d/cuda/llama-server"
  chmod +x "$BIN_DIR/llama.cpp.d/cuda/llama-server"
  printf 'revision=b10252\ntoolkit=12.4\narchitectures=86\n' > "$CONF_DIR/$LOCALAI_CUDA_META_FILE"

  run cuda_installed_revision
  [ "$status" -eq 0 ]
  [ "$output" = "b10252" ]
}

@test "cuda_installed_revision prints nothing when the cuda slot has no binary, even if metadata exists" {
  BIN_DIR="$BATS_TEST_TMPDIR/bin2"
  CONF_DIR="$BATS_TEST_TMPDIR/conf2"
  LOCALAI_CUDA_META_FILE="llama-cpp-cuda-meta"
  mkdir -p "$BIN_DIR" "$CONF_DIR"
  printf 'revision=b10252\ntoolkit=12.4\narchitectures=86\n' > "$CONF_DIR/$LOCALAI_CUDA_META_FILE"

  run cuda_installed_revision
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- cuda_build_llama_cpp: CMake receives the right flags ---

@test "cuda_build_llama_cpp configures CMake with GGML_CUDA, compiler, and architectures" {
  # git clone --depth 1 --branch <rev> <url> <target-dir>: target dir is the
  # last argument.
  mock_bin git 'mkdir -p "${@: -1}"'
  mock_bin cmake '
    log="'"$BATS_TEST_TMPDIR"'/cmake.log"
    printf "%s\n" "$*" >> "$log"
    build_dir=""
    is_build=0
    prev=""
    for arg in "$@"; do
      case "$prev" in
        -B|--build) build_dir="$arg" ;;
      esac
      [ "$arg" = "--target" ] && is_build=1
      prev="$arg"
    done
    if [ "$is_build" = "1" ] && [ -n "$build_dir" ]; then
      mkdir -p "$build_dir/bin"
      : > "$build_dir/bin/llama-server"
      chmod +x "$build_dir/bin/llama-server"
    fi
  '

  work_dir="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work_dir"
  run --separate-stderr cuda_build_llama_cpp "b1234" "/usr/local/cuda/bin/nvcc" "" "86" "https://example.invalid/llama.cpp.git" "" "$work_dir"
  [ "$status" -eq 0 ]
  [ -x "$output/llama-server" ]

  grep -q -- "-DGGML_CUDA=ON" "$BATS_TEST_TMPDIR/cmake.log"
  grep -q -- "-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc" "$BATS_TEST_TMPDIR/cmake.log"
  grep -q -- "-DCMAKE_CUDA_ARCHITECTURES=86" "$BATS_TEST_TMPDIR/cmake.log"
}

@test "a failed CUDA configure does not touch an existing installed binary" {
  mock_bin git 'mkdir -p "$3"'
  mock_bin cmake 'exit 1'

  BIN_DIR="$BATS_TEST_TMPDIR/installed-bin"
  mkdir -p "$BIN_DIR/llama.cpp"
  : > "$BIN_DIR/llama.cpp/llama-server"
  chmod +x "$BIN_DIR/llama.cpp/llama-server"

  work_dir="$BATS_TEST_TMPDIR/work2"
  mkdir -p "$work_dir"
  run cuda_build_llama_cpp "b1234" "/usr/local/cuda/bin/nvcc" "" "86" "https://example.invalid/llama.cpp.git" "" "$work_dir"
  [ "$status" -eq 1 ]

  [ -x "$BIN_DIR/llama.cpp/llama-server" ]
}

# --- cuda_build_and_install: cache check + activation on the cuda slot ---

@test "cuda_build_and_install rebuilds when the cuda slot has no binary yet, even if metadata matches" {
  # The multi-backend layout keeps each backend in its own persistent slot
  # ($BIN_DIR/llama.cpp.d/<backend>), so a stale/leftover cuda metadata file
  # must never be trusted unless that slot's own binary actually exists --
  # this is what "switching to vulkan never touched the cuda slot" and "cuda
  # was never actually built yet" both look like from cuda_build_and_install's
  # point of view.
  mock_bin nvcc 'echo "release 12.4"'

  BIN_DIR="$BATS_TEST_TMPDIR/bindir"
  CONF_DIR="$BATS_TEST_TMPDIR/confdir"
  mkdir -p "$BIN_DIR" "$CONF_DIR"

  LOCALAI_BACKEND_FILE="llama-cpp-backend"
  LOCALAI_CUDA_META_FILE="llama-cpp-cuda-meta"
  LLAMA_CPP_BACKEND="cuda"
  LLAMA_CPP_VERSION="b1234"

  # A leftover metadata file that WOULD match a fresh cuda request, but no
  # binary actually exists at $BIN_DIR/llama.cpp.d/cuda yet.
  cuda_build_cache_key "b1234" "$(command -v nvcc)" "86" > "$CONF_DIR/$LOCALAI_CUDA_META_FILE"

  # Stand-ins for lib/install.sh functions (not sourced in this test file): a
  # real rebuild attempt reaches these.
  activate_llama_cpp_backend() {
    echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  install_llama_cpp_release_dir() {
    mkdir -p "$BIN_DIR/llama.cpp.d/cuda"
    : > "$BIN_DIR/llama.cpp.d/cuda/llama-server"
    chmod +x "$BIN_DIR/llama.cpp.d/cuda/llama-server"
    activate_llama_cpp_backend
  }
  cuda_resolve_architectures() { echo "86"; }
  cuda_build_llama_cpp() { echo "$BATS_TEST_TMPDIR/fake-release"; }
  cuda_verify_build() { return 0; }

  work_dir="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work_dir"
  run cuda_build_and_install "$work_dir"
  [ "$status" -eq 0 ]
  [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "cuda" ]
}

@test "cuda_build_and_install skips rebuilding and just activates when the cuda slot already matches" {
  mock_bin nvcc 'echo "release 12.4"'

  BIN_DIR="$BATS_TEST_TMPDIR/bindir2"
  CONF_DIR="$BATS_TEST_TMPDIR/confdir2"
  mkdir -p "$BIN_DIR/llama.cpp.d/cuda" "$CONF_DIR"
  : > "$BIN_DIR/llama.cpp.d/cuda/llama-server"
  chmod +x "$BIN_DIR/llama.cpp.d/cuda/llama-server"

  LOCALAI_BACKEND_FILE="llama-cpp-backend"
  LOCALAI_CUDA_META_FILE="llama-cpp-cuda-meta"
  LLAMA_CPP_BACKEND="cuda"
  LLAMA_CPP_VERSION="b1234"

  # e.g. vulkan is currently active, but a matching cuda build already sits
  # in its own slot from an earlier install -- switching back should just
  # activate it, not rebuild.
  printf 'vulkan' > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  cuda_build_cache_key "b1234" "$(command -v nvcc)" "86" > "$CONF_DIR/$LOCALAI_CUDA_META_FILE"

  # If a rebuild were attempted, this would run, proving the skip path was
  # NOT taken.
  install_llama_cpp_release_dir() {
    echo "should-not-run" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  activate_llama_cpp_backend() {
    echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  }
  cuda_resolve_architectures() { echo "86"; }

  work_dir="$BATS_TEST_TMPDIR/work3"
  mkdir -p "$work_dir"
  run cuda_build_and_install "$work_dir"
  [ "$status" -eq 0 ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "cuda" ]
}
