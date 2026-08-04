#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
#
# CUDA backend support: detection, host-compiler probing, Vulkan capability
# check (for `auto` fallback), source build, and verification. Relies on
# fail() from the sourcing script (same convention as lib/install.sh) and on
# BIN_DIR/CONF_DIR/LLAMA_CPP_BACKEND/LLAMA_CPP_VERSION globals that
# install-local-ai.sh and update-local-ai.sh already set.

# Several functions below return their actual result via stdout through
# command substitution (backend name, nvcc path, built release dir, ...).
# The caller's own log() also writes to stdout, so it must never be used
# in here -- anything it printed would silently become part of the
# captured value. cuda_log() is the same visual format, explicitly on
# stderr, safe to call from anywhere in this file.
cuda_log() {
  printf '\n==> %s\n' "$*" >&2
}

###############################################################################
# Detection
###############################################################################

cuda_has_working_driver() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local names
  names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)" || return 1
  [ -n "$names" ]
}

cuda_driver_version() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | awk 'NR==1{print; exit}'
}

# nvcc discovery precedence: explicit LOCALAI_NVCC, then PATH, then common
# install locations, then versioned /usr/local/cuda-* (highest version first,
# stable ordering -- never picks nondeterministically among several).
cuda_find_nvcc() {
  local candidate

  if [ -n "${LOCALAI_NVCC:-}" ]; then
    if [ -x "$LOCALAI_NVCC" ] && "$LOCALAI_NVCC" --version >/dev/null 2>&1; then
      printf '%s\n' "$LOCALAI_NVCC"
      return 0
    fi
    return 1
  fi

  if command -v nvcc >/dev/null 2>&1; then
    candidate="$(command -v nvcc)"
    if "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  for candidate in /usr/local/cuda/bin/nvcc /opt/cuda/bin/nvcc /usr/lib/cuda/bin/nvcc; do
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    candidate="$candidate/bin/nvcc"
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find /usr/local -maxdepth 1 -name 'cuda-*' -type d 2>/dev/null | sort -Vr)

  return 1
}

cuda_toolkit_version() {
  local nvcc="$1"
  "$nvcc" --version 2>/dev/null | awk -F'[ ,]+' '
    { for (i = 1; i <= NF; i++) if ($i == "release") { print $(i + 1); exit } }
  '
}

# Composite check used by auto/explicit resolution: prints the usable nvcc
# path on success, fails (nothing printed) unless BOTH a working driver and a
# usable nvcc are present. nvidia-smi reporting a "CUDA Version" is NOT
# sufficient on its own -- that's the driver's max supported runtime, not
# proof the Toolkit/compiler is installed.
cuda_environment_status() {
  cuda_has_working_driver || return 1
  cuda_find_nvcc
}

# 8.6 -> 86, 12.0 -> 120; multiple GPUs are deduplicated and sorted, joined
# with ';' for CMAKE_CUDA_ARCHITECTURES.
cuda_detect_architectures() {
  local caps
  caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)" || return 1
  [ -n "$caps" ] || return 1

  printf '%s\n' "$caps" |
    tr -d ' \r' |
    awk -F'.' 'NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "%s%s\n", $1, $2}' |
    sort -un |
    paste -sd';' -
}

# Whitelist: auto/native/all-major keywords, or one or more numeric
# architecture identifiers separated by semicolons. Rejects everything else
# (command substitution, whitespace payloads, shell metacharacters) before it
# ever reaches CMake.
cuda_validate_architectures() {
  case "$1" in
    auto|native|all-major) return 0 ;;
  esac
  [[ "$1" =~ ^[0-9]+(\;[0-9]+)*$ ]]
}

cuda_resolve_architectures() {
  local requested="${1:-auto}"

  cuda_validate_architectures "$requested" || return 1
  case "$requested" in
    auto) cuda_detect_architectures ;;
    *) printf '%s\n' "$requested" ;;
  esac
}

###############################################################################
# Vulkan capability check (for `auto` fallback only -- never gates explicit
# LLAMA_CPP_BACKEND=vulkan, which is unchanged). Checking that the loader and
# an ICD are actually present is stronger than just checking `vulkaninfo`
# exists, which may be absent even on a perfectly usable system.
###############################################################################

vulkan_is_usable() {
  if command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary >/dev/null 2>&1 && return 0
  fi

  ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1' || return 1

  local icd_dir
  for icd_dir in /usr/share/vulkan/icd.d /etc/vulkan/icd.d; do
    [ -d "$icd_dir" ] || continue
    find "$icd_dir" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null | grep -q . && return 0
  done
  return 1
}

###############################################################################
# Backend resolution
###############################################################################

# auto: CUDA when fully usable, else Vulkan when actually usable, else CPU.
# Never redirects AMD/Intel systems to CUDA -- this only ever returns cuda,
# vulkan, or cpu.
cuda_resolve_auto_backend() {
  if cuda_environment_status >/dev/null 2>&1; then
    printf 'cuda\n'
  elif vulkan_is_usable; then
    printf 'vulkan\n'
  else
    printf 'cpu\n'
  fi
}

# Explicit LLAMA_CPP_BACKEND=cuda is strict by default: missing driver/nvcc
# fails clearly and actionably. Only falls back (to vulkan, else cpu) when
# LOCALAI_CUDA_FALLBACK=1. Prints the backend that should actually be used.
cuda_resolve_explicit_backend() {
  local nvcc reason=""

  if ! cuda_has_working_driver; then
    reason="no working NVIDIA GPU/driver was found (nvidia-smi)"
  elif ! nvcc="$(cuda_find_nvcc)"; then
    reason="an NVIDIA GPU and driver were found, but nvcc was not found. nvidia-smi reporting a CUDA version is not proof the CUDA Toolkit is installed -- install a compatible CUDA Toolkit or set LOCALAI_NVCC=/path/to/nvcc"
  fi

  if [ -z "$reason" ]; then
    cuda_log "NVIDIA driver detected"
    cuda_log "CUDA Toolkit detected: $(cuda_toolkit_version "$nvcc") ($nvcc)"
    printf 'cuda\n'
    return 0
  fi

  if [ "${LOCALAI_CUDA_FALLBACK:-1}" != "1" ]; then
    fail "LLAMA_CPP_BACKEND=cuda: $reason. Set LOCALAI_CUDA_FALLBACK=1 to fall back automatically, or choose another backend."
  fi

  echo "Warning: LLAMA_CPP_BACKEND=cuda requested but $reason; falling back (LOCALAI_CUDA_FALLBACK=1)." >&2
  if vulkan_is_usable; then
    printf 'vulkan\n'
  else
    printf 'cpu\n'
  fi
}

###############################################################################
# Host compiler compatibility
###############################################################################

# Real compile probe rather than string-matching nvcc's error text -- nvcc
# rejects host compilers it doesn't recognize as a hard error, so a tiny .cu
# compile is a reliable, version-independent check.
cuda_probe_host_compiler() {
  local nvcc="$1" compiler="$2" probe_dir status

  probe_dir="$(mktemp -d)"
  cat > "$probe_dir/probe.cu" <<'EOF'
__global__ void probe_kernel() {}
int main() { return 0; }
EOF

  if [ -n "$compiler" ]; then
    "$nvcc" -ccbin "$compiler" -c "$probe_dir/probe.cu" -o "$probe_dir/probe.o" >"$probe_dir/log" 2>&1
  else
    "$nvcc" -c "$probe_dir/probe.cu" -o "$probe_dir/probe.o" >"$probe_dir/log" 2>&1
  fi
  status=$?
  rm -rf "$probe_dir"
  return "$status"
}

# Prints the host compiler path to pass as CMAKE_CUDA_HOST_COMPILER, or
# prints nothing (success) when nvcc's default host compiler already works.
# Fails only when nvcc rejects every candidate, including ones already on the
# system -- installing a new compiler package is left to the caller.
cuda_resolve_host_compiler() {
  local nvcc="$1" candidate

  if cuda_probe_host_compiler "$nvcc" ""; then
    printf '\n'
    return 0
  fi

  for candidate in g++-13 g++-12 g++-11; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      cuda_probe_host_compiler "$nvcc" "$(command -v "$candidate")"; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

###############################################################################
# Build
###############################################################################

cuda_require_build_tools() {
  command -v git >/dev/null 2>&1 || fail "git is required for CUDA source builds; install it and retry."
  command -v cmake >/dev/null 2>&1 || fail "cmake is required for CUDA source builds; install it and retry."
}

# Clones the pinned llama.cpp revision, configures + builds only the
# llama-server target with GGML_CUDA=ON, and prints the directory containing
# the built llama-server (and its shared libs) on success.
cuda_build_llama_cpp() {
  local revision="$1" nvcc="$2" host_compiler="$3" architectures="$4"
  local source_url="$5" jobs="$6" work_dir="$7"
  local src_dir="$work_dir/src" build_dir="$work_dir/build"
  local generator=Ninja cmake_args llama_server_real

  cuda_require_build_tools

  cuda_log "Fetching llama.cpp $revision source"
  git clone --depth 1 --branch "$revision" "$source_url" "$src_dir" >"$work_dir/clone.log" 2>&1 ||
    fail "failed to clone llama.cpp $revision from $source_url. See $work_dir/clone.log"

  command -v ninja >/dev/null 2>&1 || generator=Make

  cmake_args=(
    -S "$src_dir" -B "$build_dir"
    -DGGML_CUDA=ON
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DCMAKE_CUDA_COMPILER="$nvcc"
    -DCMAKE_CUDA_ARCHITECTURES="$architectures"
  )
  [ "$generator" = "Ninja" ] && cmake_args+=(-G Ninja)
  [ -n "$host_compiler" ] && cmake_args+=(-DCMAKE_CUDA_HOST_COMPILER="$host_compiler")

  cuda_log "Configuring CUDA build (architectures: $architectures)"
  cmake "${cmake_args[@]}" >"$work_dir/configure.log" 2>&1 ||
    fail "CUDA configure failed for architectures $architectures. Review $work_dir/configure.log or set LOCALAI_CUDA_ARCHITECTURES explicitly."

  cuda_log "Compiling llama-server (source builds take longer than a prebuilt install)"
  cmake --build "$build_dir" --target llama-server -j "${jobs:-$(nproc 2>/dev/null || printf 4)}" \
    >"$work_dir/build.log" 2>&1 ||
    fail "CUDA compilation failed for architectures $architectures with toolkit $(cuda_toolkit_version "$nvcc"). Review $work_dir/build.log or set LOCALAI_CUDA_ARCHITECTURES explicitly."

  llama_server_real="$(find "$build_dir" -type f -name llama-server -print -quit)"
  [ -n "$llama_server_real" ] || fail "llama-server was not found after the CUDA build"
  dirname "$llama_server_real"
}

###############################################################################
# Verification
###############################################################################

# Compilation success is not sufficient -- verifies the staged binary runs
# and that --list-devices actually exposes a CUDA/NVIDIA device before it is
# ever installed over the working binary.
cuda_verify_build() {
  local dir="$1" output
  local server="$dir/llama-server"

  LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$server" --help >/dev/null 2>&1 ||
    fail "CUDA build verification failed: 'llama-server --help' did not run."

  output="$(LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$server" --list-devices 2>&1)"
  case "$output" in
    *CUDA*NVIDIA*|*NVIDIA*CUDA*)
      return 0
      ;;
  esac
  fail "CUDA build verification failed: 'llama-server --list-devices' did not report a CUDA/NVIDIA device. Output was:
$output"
}

###############################################################################
# Build cache -- avoids rebuilding on every install/update when the revision,
# toolkit, architectures, and compiler haven't changed.
###############################################################################

cuda_build_cache_key() {
  local revision="$1" nvcc="$2" architectures="$3"
  printf 'revision=%s\ntoolkit=%s\narchitectures=%s\n' \
    "$revision" "$(cuda_toolkit_version "$nvcc")" "$architectures"
}

cuda_build_cache_matches() {
  local meta_file="$1" expected_key="$2"
  [ -f "$meta_file" ] || return 1
  [ "$(grep -v '^built_at=' "$meta_file")" = "$expected_key" ]
}

# cuda_installed_revision: prints the llama.cpp revision recorded in the
# cuda build metadata file, if the cuda slot actually has a binary. Unlike
# upstream's prebuilt releases, a shallow `git clone --depth 1` build
# doesn't reliably self-report its upstream tag via `llama-server --version`
# (git-describe-style version stamping needs full history, so it typically
# just prints "1"), so the revision recorded here at build time -- not the
# binary's own --version output -- is the trustworthy source for update
# comparisons.
cuda_installed_revision() {
  [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ] || return 0
  awk -F= '$1 == "revision" {print $2; exit}' "$CONF_DIR/$LOCALAI_CUDA_META_FILE" 2>/dev/null
}

###############################################################################
# Orchestration: build, verify, and install (or skip if already cached).
# Uses BIN_DIR/CONF_DIR/LLAMA_CPP_BACKEND/LLAMA_CPP_VERSION globals and
# log()/fail()/install_llama_cpp_release_dir() from the caller/lib/install.sh.
###############################################################################

cuda_build_and_install() {
  local tmp_dir="$1"
  local nvcc host_compiler architectures meta_file build_dir release_dir cache_key

  nvcc="$(cuda_find_nvcc)" || fail "CUDA build requested but nvcc is no longer available"
  architectures="$(cuda_resolve_architectures "${LOCALAI_CUDA_ARCHITECTURES:-auto}")" ||
    fail "invalid LOCALAI_CUDA_ARCHITECTURES value: ${LOCALAI_CUDA_ARCHITECTURES:-auto}"
  [ -n "$architectures" ] ||
    fail "could not detect CUDA compute capability from nvidia-smi; set LOCALAI_CUDA_ARCHITECTURES explicitly (e.g. 86)"

  meta_file="$CONF_DIR/$LOCALAI_CUDA_META_FILE"
  cache_key="$(cuda_build_cache_key "$LLAMA_CPP_VERSION" "$nvcc" "$architectures")"
  # cuda has its own persistent slot ($BIN_DIR/llama.cpp.d/cuda) that survives
  # switching to another backend and back, so that slot -- not whatever is
  # currently active -- is the authoritative record of "is a matching cuda
  # build already here".
  if [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ] && cuda_build_cache_matches "$meta_file" "$cache_key"; then
    cuda_log "CUDA build for $LLAMA_CPP_VERSION / $architectures already installed; skipping rebuild"
    activate_llama_cpp_backend
    return 0
  fi

  host_compiler="$(cuda_resolve_host_compiler "$nvcc")" ||
    fail "nvcc did not accept the default host C++ compiler and no compatible g++ (11/12/13) was found. Install one (for example: sudo apt-get install g++-13) or point LOCALAI_NVCC at a toolkit that matches your compiler."

  build_dir="$tmp_dir/cuda-build"
  mkdir -p "$build_dir"
  release_dir="$(cuda_build_llama_cpp "$LLAMA_CPP_VERSION" "$nvcc" "$host_compiler" "$architectures" "$LLAMA_CPP_SOURCE_URL" "${LOCALAI_BUILD_JOBS:-}" "$build_dir")" ||
    return 1

  cuda_log "Verifying CUDA build"
  cuda_verify_build "$release_dir" || return 1

  install_llama_cpp_release_dir "$release_dir" "$tmp_dir"
  {
    printf '%s\n' "$cache_key"
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta_file"
}
