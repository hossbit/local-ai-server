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

  # grep without -q consumes all of ldconfig's output, so ldconfig cannot
  # receive SIGPIPE and fail the pipeline under `set -o pipefail`.
  ldconfig -p 2>/dev/null | grep 'libvulkan\.so\.1' >/dev/null || return 1

  local icd_dir
  for icd_dir in /usr/share/vulkan/icd.d /etc/vulkan/icd.d; do
    [ -d "$icd_dir" ] || continue
    find "$icd_dir" -maxdepth 1 -name '*.json' -print -quit 2>/dev/null | grep . >/dev/null && return 0
  done
  return 1
}

###############################################################################
# Backend resolution
###############################################################################

# LOCALAI_CUDA_BUILD selects how the cuda backend is installed: `source`
# compiles llama.cpp against the local CUDA Toolkit; `prebuilt` downloads
# upstream's Ubuntu CUDA archive plus its CUDA runtime libraries and needs only
# a working NVIDIA driver. Empty (the default) keeps the method the installed
# cuda slot was made with, and means `source` for a new install -- so a choice
# passed only as an environment variable at install time survives later
# `localai update` runs, which do not see that variable.
cuda_effective_build_mode() {
  if [ -n "${LOCALAI_CUDA_BUILD:-}" ]; then
    printf '%s\n' "$LOCALAI_CUDA_BUILD"
  elif [ -n "${BIN_DIR:-}" ] && [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ] &&
    [ "$(cuda_meta_value method)" = "prebuilt" ]; then
    printf 'prebuilt\n'
  else
    printf 'source\n'
  fi
}

cuda_prebuilt_selected() {
  [ "$(cuda_effective_build_mode)" = "prebuilt" ]
}

cuda_validate_build_mode() {
  case "${LOCALAI_CUDA_BUILD:-}" in
    ''|source|prebuilt) return 0 ;;
  esac
  fail "invalid LOCALAI_CUDA_BUILD: ${LOCALAI_CUDA_BUILD}. Use source or prebuilt."
}

# auto: CUDA when fully usable, else Vulkan when actually usable, else CPU.
# Never redirects AMD/Intel systems to CUDA -- this only ever returns cuda,
# vulkan, or cpu. With LOCALAI_CUDA_BUILD=prebuilt a working driver is enough.
cuda_resolve_auto_backend() {
  if cuda_environment_status >/dev/null 2>&1; then
    printf 'cuda\n'
  elif cuda_prebuilt_selected && cuda_has_working_driver; then
    printf 'cuda\n'
  elif vulkan_is_usable; then
    printf 'vulkan\n'
  else
    printf 'cpu\n'
  fi
}

# cuda_toolkit_install_hint: one-line-per-item, copy-pasteable next step for
# installing the CUDA Toolkit (nvcc). Never attempted automatically -- see
# README.md/wiki for why (it can pull in its own NVIDIA driver as a
# dependency, conflicting with one already installed). Keyed off the same
# package-manager detection install_system_dependencies (lib/install.sh)
# already uses, not distro ID, so it stays consistent with whatever
# actually installed everything else on this system.
cuda_toolkit_install_hint() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '  sudo apt-get install nvidia-cuda-toolkit\n  (Debian/Ubuntu repos often lag behind NVIDIA'"'"'s own releases -- for a newer\n  version, use NVIDIA'"'"'s own repo instead: https://developer.nvidia.com/cuda-downloads)'
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    printf '  Fedora/RHEL do not ship the CUDA Toolkit in their own repositories.\n  Install it from NVIDIA'"'"'s official CUDA repo: https://developer.nvidia.com/cuda-downloads'
  else
    printf '  https://developer.nvidia.com/cuda-downloads'
  fi
}

# Explicit LLAMA_CPP_BACKEND=cuda is strict by default: missing driver/nvcc
# fails clearly and actionably. Only falls back (to vulkan, else cpu) when
# LOCALAI_CUDA_FALLBACK=1. Prints the backend that should actually be used.
#
# Every fail()/warning message below follows the same shape so a user
# scanning quickly can find the part they need without rereading a run-on
# paragraph: one-line summary, then (if useful) one line of context, then a
# "Fix:"/"Or, ...:" block with the exact command or setting on its own
# indented line.
cuda_resolve_explicit_backend() {
  local nvcc reason="" hint=""

  if ! cuda_has_working_driver; then
    reason="no working NVIDIA GPU/driver was found (nvidia-smi)"
    hint="If you do have an NVIDIA GPU, install or update its driver, then retry."
  elif cuda_prebuilt_selected; then
    cuda_log "NVIDIA driver detected: $(cuda_driver_version) (prebuilt CUDA build; no CUDA Toolkit needed)"
    printf 'cuda\n'
    return 0
  elif ! nvcc="$(cuda_find_nvcc)"; then
    reason="an NVIDIA GPU and driver were found, but nvcc was not found"
    hint="nvidia-smi reporting a CUDA version is not proof the CUDA Toolkit is installed.

Fix:
  Already have a CUDA Toolkit? Point at it: LOCALAI_NVCC=/path/to/nvcc

Or, use upstream's prebuilt CUDA build (needs only the driver):
  LOCALAI_CUDA_BUILD=prebuilt

Or, install a CUDA Toolkit:
$(cuda_toolkit_install_hint)"
  fi

  if [ -z "$reason" ]; then
    cuda_log "NVIDIA driver detected"
    cuda_log "CUDA Toolkit detected: $(cuda_toolkit_version "$nvcc") ($nvcc)"
    printf 'cuda\n'
    return 0
  fi

  if [ "${LOCALAI_CUDA_FALLBACK:-0}" != "1" ]; then
    fail "cuda backend requested, but $reason.

$hint

Or, skip fixing this:
  LOCALAI_CUDA_FALLBACK=1 falls back to another backend automatically
  Choose a different backend yourself: vulkan, cpu, auto, ..."
  fi

  echo "Warning: cuda backend requested, but $reason -- falling back automatically (LOCALAI_CUDA_FALLBACK=1)." >&2
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

# cuda_build_tools_install_hint: distro-aware install command for the ordinary
# build tooling a CUDA source build needs (compiler toolchain, cmake, git).
# Unlike the CUDA Toolkit itself (cuda_toolkit_install_hint), these are the
# same generic packages install-local-ai.sh already installs automatically
# for a fresh LLAMA_CPP_BACKEND=cuda install -- safe to name a direct command
# for, just not (yet) auto-installed from this runtime path.
cuda_build_tools_install_hint() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '  sudo apt-get install build-essential cmake git'
  elif command -v dnf >/dev/null 2>&1; then
    printf '  sudo dnf install gcc gcc-c++ make cmake git'
  elif command -v yum >/dev/null 2>&1; then
    printf '  sudo yum install gcc gcc-c++ make cmake git'
  else
    printf '  Install a C/C++ compiler, cmake, and git.'
  fi
}

cuda_require_build_tools() {
  local missing=()

  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v cmake >/dev/null 2>&1 || missing+=(cmake)
  [ "${#missing[@]}" -eq 0 ] && return 0

  fail "missing build tool(s) required for CUDA source builds: ${missing[*]}

Fix:
$(cuda_build_tools_install_hint)"
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
    fail "CUDA configure failed for architectures $architectures.

Fix:
  Review the full error: $work_dir/configure.log

Or:
  Set LOCALAI_CUDA_ARCHITECTURES explicitly instead of auto-detecting."

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

# cuda_meta_value KEY: one field of the cuda metadata file. Files written
# before LOCALAI_CUDA_BUILD existed (and every source build, whose cache key
# must stay byte-for-byte unchanged) carry no `method` line.
cuda_meta_value() {
  [ -n "${CONF_DIR:-}" ] && [ -n "${LOCALAI_CUDA_META_FILE:-}" ] || return 0
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
    "$CONF_DIR/$LOCALAI_CUDA_META_FILE" 2>/dev/null
}

cuda_installed_method() {
  local method
  method="$(cuda_meta_value method)"
  printf '%s\n' "${method:-source}"
}

# cuda_installed_revision_for_mode: like cuda_installed_revision, but empty
# when the installed cuda slot was made by the other LOCALAI_CUDA_BUILD
# method, so `localai update` reinstalls it the requested way.
cuda_installed_revision_for_mode() {
  [ "$(cuda_installed_method)" = "$(cuda_effective_build_mode)" ] || return 0
  cuda_installed_revision
}

###############################################################################
# Prebuilt CUDA (LOCALAI_CUDA_BUILD=prebuilt). Upstream publishes
# llama-<tag>-bin-ubuntu-cuda-<X.Y>-x64.tar.gz plus a matching
# cudart-llama-<tag>-bin-ubuntu-cuda-<X.Y>-x64.tar.gz with libcudart/libcublas.
# Each CUDA line needs a minimum driver; the newest line the driver supports
# is tried first, and a build is installed only after it reports a CUDA device.
###############################################################################

# cuda_prebuilt_min_driver X.Y: minimum NVIDIA driver major version for a
# prebuilt CUDA X.Y build (the driver each CUDA major line shipped with for
# the published 12.8 and 13.x builds). Unknown lines need an explicit
# LOCALAI_CUDA_PREBUILT_VERSION.
cuda_prebuilt_min_driver() {
  case "${1%%.*}" in
    12) printf '570\n' ;;
    13) printf '580\n' ;;
    *) return 1 ;;
  esac
}

# cuda_prebuilt_versions JSON: CUDA versions with a Linux x64 archive in the
# release, newest first.
cuda_prebuilt_versions() {
  jq -r '.assets[].name' <<<"$1" 2>/dev/null |
    sed -nE 's/^llama-.*-bin-ubuntu-cuda-([0-9]+\.[0-9]+)-x64\.tar\.gz$/\1/p' |
    sort -Vru
}

# cuda_prebuilt_candidates JSON: versions to try, newest first. An explicit
# LOCALAI_CUDA_PREBUILT_VERSION skips the driver check (verification still runs).
cuda_prebuilt_candidates() {
  local json="$1" version min driver_major

  if [ -n "${LOCALAI_CUDA_PREBUILT_VERSION:-}" ]; then
    cuda_prebuilt_versions "$json" | grep -Fx -- "$LOCALAI_CUDA_PREBUILT_VERSION" || true
    return 0
  fi

  driver_major="$(cuda_driver_version)"
  driver_major="${driver_major%%.*}"
  [[ "$driver_major" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r version; do
    min="$(cuda_prebuilt_min_driver "$version")" || continue
    [ "$driver_major" -ge "$min" ] && printf '%s\n' "$version"
  done < <(cuda_prebuilt_versions "$json")
}

cuda_prebuilt_asset_re() {
  local kind="$1" version="$2"
  printf '^%s-.*-bin-ubuntu-cuda-%s-x64\\.tar\\.gz$\n' "$kind" "${version//./\\.}"
}

# cuda_prebuilt_runs DIR: true when the staged llama-server runs and lists a
# CUDA/NVIDIA device (the non-fatal form of cuda_verify_build).
cuda_prebuilt_runs() {
  local dir="$1" output
  output="$(LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$dir/llama-server" --list-devices 2>&1)" || return 1
  case "$output" in
    *CUDA*NVIDIA*|*NVIDIA*CUDA*) return 0 ;;
  esac
  return 1
}

# cuda_prebuilt_reuse_runtime VERSION DEST: copies the CUDA runtime libraries
# from the installed prebuilt cuda slot when it uses the same CUDA version, so
# each update downloads only the ~210 MB llama.cpp archive instead of also
# the ~400-570 MB runtime archive. Fails when there is nothing to reuse.
cuda_prebuilt_reuse_runtime() {
  local version="$1" dest="$2" slot="$BIN_DIR/llama.cpp.d/cuda" files file

  [ -x "$slot/llama-server" ] || return 1
  [ "$(cuda_installed_method)" = "prebuilt" ] || return 1
  [ "$(cuda_meta_value cuda_runtime)" = "$version" ] || return 1
  files="$(cuda_meta_value cudart_files)"
  [ -n "$files" ] || return 1
  for file in $files; do
    [[ "$file" =~ ^[A-Za-z0-9._+-]+$ ]] && [ -e "$slot/$file" ] || return 1
  done
  for file in $files; do
    cp -a -- "$slot/$file" "$dest/$file" || return 1
  done
  printf '%s\n' "$files"
}

# cuda_prebuilt_fetch_runtime JSON VERSION WORK DEST: downloads and extracts
# the matching cudart archive into DEST; prints the library file names.
cuda_prebuilt_fetch_runtime() {
  local json="$1" version="$2" work="$3" dest="$4" url file

  url="$(release_asset_url "$json" "$(cuda_prebuilt_asset_re cudart-llama "$version")")"
  if [ -z "$url" ]; then
    echo "Warning: no CUDA $version runtime archive in this release; relying on system CUDA libraries." >&2
    return 0
  fi
  cuda_log "Downloading CUDA $version runtime libraries (only needed once per CUDA version)"
  download_verified_asset "$json" "$url" "$work/cudart.tar.gz" "CUDA $version runtime"
  mkdir -p "$work/cudart"
  tar -xzf "$work/cudart.tar.gz" -C "$work/cudart" || fail "failed to extract the CUDA $version runtime"
  rm -f -- "$work/cudart.tar.gz"
  while IFS= read -r file; do
    cp -a -- "$file" "$dest/" || return 1
    basename -- "$file"
  done < <(find "$work/cudart" -name 'lib*.so*' \( -type f -o -type l \) | sort)
}

cuda_prebuilt_install() {
  local tmp_dir="$1"
  local json version url digest work server release_dir files meta_file
  local -a versions=()

  meta_file="$CONF_DIR/$LOCALAI_CUDA_META_FILE"
  cuda_has_working_driver || {
    echo "Error: the prebuilt CUDA build needs a working NVIDIA driver (nvidia-smi)." >&2
    return 1
  }
  json="${LLAMA_CPP_BINARY_JSON:-}"
  [ -n "$json" ] || json="$(resolve_llama_cpp_binary_json "$LLAMA_CPP_JSON")"
  mapfile -t versions < <(cuda_prebuilt_candidates "$json")

  if [ "${#versions[@]}" -eq 0 ]; then
    cat >&2 <<EOF
Error: llama.cpp $LLAMA_CPP_VERSION has no prebuilt CUDA build for NVIDIA driver $(cuda_driver_version).
Available CUDA builds: $(cuda_prebuilt_versions "$json" | paste -sd' ' -)

Fix:
  Update the NVIDIA driver (CUDA 12.x builds need 570+, CUDA 13.x need 580+).

Or:
  Force one build: LOCALAI_CUDA_PREBUILT_VERSION=12.8
  Build from source with a CUDA Toolkit: LOCALAI_CUDA_BUILD=source
EOF
    return 1
  fi

  # Same release, same CUDA line, already installed the prebuilt way.
  if [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ] &&
    [ "$(cuda_installed_method)" = "prebuilt" ] &&
    [ "$(cuda_meta_value revision)" = "$LLAMA_CPP_VERSION" ] &&
    [ "$(cuda_meta_value cuda_runtime)" = "${versions[0]}" ]; then
    cuda_log "Prebuilt CUDA ${versions[0]} build for $LLAMA_CPP_VERSION already installed"
    CUDA_PREBUILT_URL="$(cuda_meta_value asset_url)"
    CUDA_PREBUILT_DIGEST="$(cuda_meta_value asset_digest)"
    activate_llama_cpp_backend
    return 0
  fi

  for version in "${versions[@]}"; do
    url="$(release_asset_url "$json" "$(cuda_prebuilt_asset_re llama "$version")")"
    [ -n "$url" ] || continue
    work="$tmp_dir/cuda-prebuilt-$version"
    rm -rf -- "$work"
    mkdir -p "$work/llama"

    cuda_log "Downloading prebuilt llama.cpp $LLAMA_CPP_VERSION (CUDA $version)"
    download_verified_asset "$json" "$url" "$work/llama.tar.gz" "llama.cpp (CUDA $version)"
    tar -xzf "$work/llama.tar.gz" -C "$work/llama" || fail "failed to extract llama.cpp (CUDA $version)"
    rm -f -- "$work/llama.tar.gz"
    server="$(find "$work/llama" -type f -name llama-server -print -quit)"
    [ -n "$server" ] || fail "llama-server was not found in the CUDA $version archive"
    release_dir="$(dirname "$server")"

    if files="$(cuda_prebuilt_reuse_runtime "$version" "$release_dir")"; then
      cuda_log "Reusing the installed CUDA $version runtime libraries"
    else
      files="$(cuda_prebuilt_fetch_runtime "$json" "$version" "$work" "$release_dir")" || return 1
    fi

    cuda_log "Verifying prebuilt CUDA $version build"
    if cuda_prebuilt_runs "$release_dir"; then
      digest="$(release_asset_digest "$json" "$url")"
      install_llama_cpp_release_dir "$release_dir" "$tmp_dir"
      {
        printf 'revision=%s\n' "$LLAMA_CPP_VERSION"
        printf 'method=prebuilt\n'
        printf 'cuda_runtime=%s\n' "$version"
        printf 'asset_url=%s\n' "$url"
        printf 'asset_digest=%s\n' "$digest"
        printf 'cudart_files=%s\n' "$(printf '%s\n' "$files" | paste -sd' ' -)"
        printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$meta_file"
      CUDA_PREBUILT_URL="$url"
      CUDA_PREBUILT_DIGEST="$digest"
      return 0
    fi
    echo "Warning: the prebuilt CUDA $version build did not detect a CUDA device on this system." >&2
    rm -rf -- "$work"
  done

  cat >&2 <<EOF
Error: no prebuilt CUDA build of llama.cpp $LLAMA_CPP_VERSION ran on this system
(driver $(cuda_driver_version)). The previously installed backend was not changed.

Fix:
  Update the NVIDIA driver, then retry.

Or:
  Build from source with a CUDA Toolkit: LOCALAI_CUDA_BUILD=source
EOF
  return 1
}

###############################################################################
# Orchestration: build, verify, and install (or skip if already cached).
# Uses BIN_DIR/CONF_DIR/LLAMA_CPP_BACKEND/LLAMA_CPP_VERSION globals and
# log()/fail()/install_llama_cpp_release_dir() from the caller/lib/install.sh.
###############################################################################

cuda_build_and_install() {
  local tmp_dir="$1"
  local nvcc host_compiler architectures meta_file build_dir release_dir cache_key

  if cuda_prebuilt_selected; then
    cuda_prebuilt_install "$tmp_dir"
    return
  fi

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
    fail "nvcc rejected the default host C++ compiler, and no compatible g++ (11/12/13) was found.

Fix:
  Install a compatible g++ alongside your default compiler, e.g.:
    sudo apt-get install g++-13

Or:
  Point LOCALAI_NVCC at a CUDA Toolkit that matches your compiler."

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
