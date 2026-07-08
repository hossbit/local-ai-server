#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

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
    *)
      fail "unsupported LLAMA_CPP_BACKEND: $LLAMA_CPP_BACKEND. Use cpu, vulkan, rocm, openvino, sycl-fp16, or sycl-fp32."
      ;;
  esac
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
    for key in LOCALAI_CTX_SIZE LOCALAI_N_GPU_LAYERS LOCALAI_THREADS LOCALAI_CACHE_TYPE_K LOCALAI_CACHE_TYPE_V LOCALAI_PARALLEL LOCALAI_BATCH_SIZE LOCALAI_UBATCH_SIZE LOCALAI_FLASH_ATTN LOCALAI_JINJA LOCALAI_MLOCK LOCALAI_NO_MMAP LOCALAI_EXTRA_LLAMA_ARGS LOCALAI_HEALTH_CHECK_TIMEOUT LOCALAI_GLOBAL_TTL; do
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
  local module

  mkdir -p "$dest_dir"
  install -m644 "$source_dir/lib/common.sh" "$dest_dir/common.sh"
  install -m644 "$source_dir/lib/install.sh" "$dest_dir/install.sh"
  if [ -d "$source_dir/lib/cli" ]; then
    mkdir -p "$dest_dir/cli"
    for module in "$source_dir"/lib/cli/*.sh; do
      [ -f "$module" ] || continue
      install -m644 "$module" "$dest_dir/cli/$(basename "$module")"
    done
  fi
}
