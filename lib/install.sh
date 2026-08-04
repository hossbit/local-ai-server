#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2153

github_api_get() {
  local url="$1"
  local body http_status
  local curl_args=(-4 --connect-timeout 10 --max-time 30 -sSL)

  body="$(mktemp)"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  http_status="$(curl "${curl_args[@]}" -o "$body" -w '%{http_code}' "$url")" || {
    rm -f "$body"
    fail "failed to fetch GitHub release metadata: $url"
  }

  if [ "$http_status" = "403" ] && grep -qi 'rate limit' "$body"; then
    rm -f "$body"
    fail "GitHub API rate limit reached while fetching $url. Set GITHUB_TOKEN and retry."
  fi

  case "$http_status" in
    2*) cat "$body" ;;
    *)
      cat "$body" >&2
      rm -f "$body"
      fail "GitHub API request failed with HTTP $http_status: $url"
      ;;
  esac
  rm -f "$body"
}

release_asset_url() {
  local json="$1"
  local pattern="$2"

  jq -er \
    --arg pattern "$pattern" \
    '.assets[] | select(.name | test($pattern)) | .browser_download_url' \
    <<<"$json" | head -n1 || true
}

release_asset_digest() {
  local json="$1"
  local url="$2"

  jq -er \
    --arg url "$url" \
    '.assets[] | select(.browser_download_url == $url) | .digest // empty' \
    <<<"$json" | head -n1 || true
}

release_api_for_version() {
  local version="$1"
  local tag_api="$2"
  local latest_api="$3"

  if [ "$version" = "latest" ]; then
    printf '%s\n' "$latest_api"
    return 0
  fi

  if [[ "$tag_api" == */tags/latest ]]; then
    printf '%s/%s\n' "${tag_api%/latest}" "$version"
  else
    printf '%s\n' "$tag_api"
  fi
}

verify_release_asset() {
  local file="$1"
  local digest="$2"
  local label="$3"

  if [ "${LOCALAI_SKIP_DIGEST:-0}" = "1" ]; then
    echo "Warning: skipping checksum verification for $label because LOCALAI_SKIP_DIGEST=1." >&2
    return 0
  fi

  case "$digest" in
    sha256:*)
      printf '%s  %s\n' "${digest#sha256:}" "$file" | sha256sum -c - >/dev/null ||
        fail "$label checksum verification failed"
      ;;
    *)
      fail "missing sha256 digest for $label release asset. If you are pinning an older release before GitHub asset digests were available, rerun with LOCALAI_SKIP_DIGEST=1 to install without checksum verification."
      ;;
  esac
}

download_verified_asset() {
  local json="$1"
  local url="$2"
  local output="$3"
  local label="$4"
  local digest

  curl -4 -fL --retry 3 --retry-delay 2 --output "$output" "$url" ||
    fail "failed to download $label"

  digest="$(release_asset_digest "$json" "$url")"
  verify_release_asset "$output" "$digest" "$label"
}

select_llama_cpp_asset_regex() {
  if [ "${1:-}" = "--detect-installed" ] && [ -z "$LLAMA_CPP_BACKEND" ]; then
    if [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ]; then
      LLAMA_CPP_BACKEND="$(<"$CONF_DIR/$LOCALAI_BACKEND_FILE")"
    elif [ -f "$AI_DIR/$LOCALAI_BACKEND_FILE" ]; then
      LLAMA_CPP_BACKEND="$(<"$AI_DIR/$LOCALAI_BACKEND_FILE")"
    else
      LLAMA_CPP_BACKEND="$LOCALAI_DEFAULT_BACKEND"
    fi
  fi

  LLAMA_CPP_BACKEND="${LLAMA_CPP_BACKEND:-$LOCALAI_DEFAULT_BACKEND}"

  # auto: CUDA when a full CUDA build environment is usable, else Vulkan when
  # actually usable, else CPU. Resolved once here so every caller downstream
  # (dependency install, asset/build selection, config generation) sees a
  # concrete backend name, never "auto" itself.
  if [ "$LLAMA_CPP_BACKEND" = "auto" ]; then
    LLAMA_CPP_BACKEND="$(cuda_resolve_auto_backend)"
  fi

  case "$LLAMA_CPP_BACKEND" in
    cpu)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_CPU_ASSET_RE"
      ;;
    vulkan)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_VULKAN_ASSET_RE"
      ;;
    rocm)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_ROCM_ASSET_RE"
      ;;
    openvino)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_OPENVINO_ASSET_RE"
      ;;
    sycl-fp16)
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_SYCL_FP16_ASSET_RE"
      ;;
    sycl-fp32|sycl)
      LLAMA_CPP_BACKEND="sycl-fp32"
      LLAMA_CPP_ASSET_RE="$LLAMA_CPP_SYCL_FP32_ASSET_RE"
      ;;
    cuda)
      # Explicit cuda is strict by default: cuda_resolve_explicit_backend
      # fails clearly unless LOCALAI_CUDA_FALLBACK=1, in which case it
      # returns the backend to actually use (vulkan or cpu) instead.
      LLAMA_CPP_BACKEND="$(cuda_resolve_explicit_backend)"
      if [ "$LLAMA_CPP_BACKEND" = "cuda" ]; then
        LLAMA_CPP_ASSET_RE=""
      else
        select_llama_cpp_asset_regex "$1"
        return
      fi
      ;;
    *)
      fail "unsupported LLAMA_CPP_BACKEND: $LLAMA_CPP_BACKEND. Use auto, cpu, vulkan, rocm, openvino, sycl-fp16, sycl-fp32, or cuda."
      ;;
  esac
}

# llama_cpp_backend_version: prints the installed version string for
# $BIN_DIR/llama.cpp.d/<backend>, or nothing if that slot doesn't exist or
# its binary won't run. Sets LD_LIBRARY_PATH to the backend's own directory
# -- unlike upstream's prebuilt releases (which typically bake in an rpath),
# a locally-built binary such as the CUDA backend needs it to find its
# sibling shared libraries, and running it without would silently look like
# "not installed" rather than an actual version mismatch.
llama_cpp_backend_version() {
  local backend="$1"
  local dir="$BIN_DIR/llama.cpp.d/$backend"
  LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$dir/llama-server" --version 2>&1 |
    awk '/version:/ {print $2; exit}' || true
}

# _llama_cpp_format_display_version: given a backend name and the raw first
# line of `llama-server --version` for it, returns the human-facing
# "version: N (hash)" line -- substituting cuda's recorded build revision
# (cuda_installed_revision, lib/cuda.sh) for its own self-reported build
# number, otherwise passing $raw straight through. A shallow
# `git clone --depth 1` build always self-reports "1" regardless of which
# revision it actually is, since llama.cpp computes that number from
# `git rev-list --count`, which only sees the one commit a shallow clone
# fetched. The commit hash portion is unaffected either way.
_llama_cpp_format_display_version() {
  local backend="$1" raw="$2"
  local hash revision

  if [ "$backend" = "cuda" ] && command -v cuda_installed_revision >/dev/null 2>&1; then
    revision="$(cuda_installed_revision)"
    if [ -n "$revision" ]; then
      hash="$(printf '%s\n' "$raw" | sed -n 's/.*(\(.*\)).*/\1/p')"
      printf 'version: %s (%s)\n' "${revision#b}" "$hash"
      return
    fi
  fi

  printf '%s\n' "$raw"
}

# llama_cpp_display_version: the corrected display version for $backend via
# $BIN_DIR/llama-server (the wrapper script/symlink, i.e. whichever backend
# is currently *active*). For `localai version` and the install/update
# summaries.
llama_cpp_display_version() {
  local backend="$1" raw
  raw="$("$BIN_DIR/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}')"
  _llama_cpp_format_display_version "$backend" "$raw"
}

# llama_cpp_backend_display_version: the corrected display version for one
# specific backend's own slot ($BIN_DIR/llama.cpp.d/<backend>), regardless
# of whether it's the currently active one. For `localai backend list`.
# Prints nothing if that slot has no binary.
llama_cpp_backend_display_version() {
  local backend="$1" dir raw
  dir="$BIN_DIR/llama.cpp.d/$backend"
  [ -x "$dir/llama-server" ] || return 0
  raw="$(LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$dir/llama-server" --version 2>&1 | awk 'NR == 1 {print; exit}')"
  _llama_cpp_format_display_version "$backend" "$raw"
}

# install_llama_cpp_release_dir: takes a directory that already contains a
# built/extracted llama-server (anywhere under it, alongside its shared
# libs), stores it under $BIN_DIR/llama.cpp.d/$LLAMA_CPP_BACKEND (keeping any
# other previously-installed backends intact), atomically repoints the
# $BIN_DIR/llama.cpp symlink at it, installs the LD_LIBRARY_PATH wrapper
# script, and persists the backend marker. Shared by the prebuilt-archive
# path (install_llama_cpp_archive) and the CUDA source build path
# (cuda_build_and_install in lib/cuda.sh) so both scripts and both backend
# kinds go through one atomic-install implementation, and so `localai
# switch` can find every backend that's ever been installed.
# activate_llama_cpp_backend: points $BIN_DIR/llama.cpp at the already-
# installed $BIN_DIR/llama.cpp.d/$LLAMA_CPP_BACKEND and persists the backend
# marker. Split out from install_llama_cpp_release_dir so cuda_build_and_install's
# cache-hit skip path (lib/cuda.sh) and `localai switch` (lib/cli/switch.sh)
# can activate an already-installed backend without reinstalling anything.
activate_llama_cpp_backend() {
  # `ln -sfn` can replace an existing symlink or file, but not a real
  # directory -- it would silently create the link *inside* one instead of
  # replacing it. A real directory here only happens once, migrating from
  # the pre-multi-backend layout where llama.cpp was the release dir itself.
  if [ -d "$BIN_DIR/llama.cpp" ] && [ ! -L "$BIN_DIR/llama.cpp" ]; then
    rm -rf "$BIN_DIR/llama.cpp"
  fi
  ln -sfn "llama.cpp.d/$LLAMA_CPP_BACKEND" "$BIN_DIR/llama.cpp"
  echo "$LLAMA_CPP_BACKEND" > "$CONF_DIR/$LOCALAI_BACKEND_FILE"
}

install_llama_cpp_release_dir() {
  local release_dir="$1"
  local tmp_dir="$2"
  local llama_server_real llama_release_dir backend_dir

  llama_server_real=$(find "$release_dir" -type f -name llama-server -print -quit)
  [ -n "$llama_server_real" ] || fail "llama-server was not found in $release_dir"
  llama_release_dir=$(dirname "$llama_server_real")

  backend_dir="$BIN_DIR/llama.cpp.d/$LLAMA_CPP_BACKEND"
  mkdir -p "$BIN_DIR/llama.cpp.d"
  rm -rf "$backend_dir"
  mv "$llama_release_dir" "$backend_dir"
  activate_llama_cpp_backend

  cat > "$tmp_dir/llama-server" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$BIN_DIR/llama.cpp:\${LD_LIBRARY_PATH:-}"
exec "$BIN_DIR/llama.cpp/llama-server" "\$@"
EOF

  install -m755 "$tmp_dir/llama-server" "$BIN_DIR/llama-server"
}

llama_cpp_versions_match() {
  local latest="$1"
  local current="$2"

  [ -n "$current" ] && [ "${latest#b}" = "${current#b}" ]
}

localai_conf_default_version() {
  local file="$1"

  [ -f "$file" ] || return 1
  awk -F':-' '
    /^LOCALAI_VERSION="/ {
      value = $2
      sub(/}".*$/, "", value)
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' "$file"
}

config_assignment_value() {
  local key="$1"
  local file="$2"

  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      # Preserve literal # characters inside values such as
      # LOCALAI_EXTRA_LLAMA_ARGS; installed configs write preserved values quoted.
      gsub(/^[[:space:]"'\'']+|[[:space:]"'\'']+$/, "", value)
      print value
    }
  ' "$file" | tail -n 1
}

append_runtime_tuning() {
  local installed_conf="$CONF_DIR/localai.conf"
  local source_conf="$1"
  local marker="$2"
  local key value had_ctx=0 had_gpu=0 had_flash=0 had_parallel=0

  {
    echo
    printf '# Runtime tuning preserved by %s.\n' "$marker"
    for key in LOCALAI_CTX_SIZE LOCALAI_N_GPU_LAYERS LOCALAI_THREADS LOCALAI_CACHE_TYPE_K LOCALAI_CACHE_TYPE_V LOCALAI_PARALLEL LOCALAI_BATCH_SIZE LOCALAI_UBATCH_SIZE LOCALAI_FLASH_ATTN LOCALAI_JINJA LOCALAI_MLOCK LOCALAI_NO_MMAP LOCALAI_EXTRA_LLAMA_ARGS LOCALAI_HEALTH_CHECK_TIMEOUT LOCALAI_GLOBAL_TTL LOCALAI_AUTO_TUNE LOCALAI_SPEC_TYPE LOCALAI_SPEC_DRAFT_N_MAX LOCALAI_MODELS_OVERRIDE_SUBDIR LOCALAI_EMBEDDING_TTL LOCALAI_PRELOAD_MODELS LOCALAI_METRICS_ENABLED; do
      value="$(config_assignment_value "$key" "$source_conf" || true)"
      if [ -n "$value" ]; then
        printf '%s="%s"\n' "$key" "$value"
        [ "$key" = "LOCALAI_CTX_SIZE" ] && had_ctx=1
        [ "$key" = "LOCALAI_N_GPU_LAYERS" ] && had_gpu=1
        [ "$key" = "LOCALAI_FLASH_ATTN" ] && had_flash=1
        [ "$key" = "LOCALAI_PARALLEL" ] && had_parallel=1
      fi
    done
    if [ "$LLAMA_CPP_BACKEND" = "cpu" ]; then
      [ "$had_ctx" -eq 1 ] || echo 'LOCALAI_CTX_SIZE="4096"'
      [ "$had_gpu" -eq 1 ] || echo 'LOCALAI_N_GPU_LAYERS="0"'
      [ "$had_flash" -eq 1 ] || echo 'LOCALAI_FLASH_ATTN="0"'
      [ "$had_parallel" -eq 1 ] || echo 'LOCALAI_PARALLEL="1"'
    fi
  } >> "$installed_conf"
}

write_systemd_user_service() {
  local service_file="$1"
  local bin_dir="$2"

  cat > "$service_file" <<EOF
[Unit]
Description=LocalAI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$bin_dir/start.sh
ExecStop=$bin_dir/stop.sh

[Install]
WantedBy=default.target
EOF
}

install_localai_libs() {
  local source_dir="$1"
  local dest_dir="$2"
  local path rel

  mkdir -p "$dest_dir"
  while IFS= read -r path; do
    rel="${path#"$source_dir/lib/"}"
    mkdir -p "$dest_dir/$(dirname "$rel")"
    install -m644 "$path" "$dest_dir/$rel"
  done < <(find "$source_dir/lib" -type f | sort)
}
