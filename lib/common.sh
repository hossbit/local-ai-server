#!/usr/bin/env bash
# shellcheck disable=SC2154

expand_path() {
  local value="$1"

  case "$value" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${value:2}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

resolve_ai_dir() {
  if [ -n "${LOCALAI_DIR:-}" ]; then
    expand_path "$LOCALAI_DIR"
  elif [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
    cd "$SCRIPT_DIR/.." && pwd
  elif [ -f "$SCRIPT_DIR/install-local-ai.sh" ]; then
    expand_path "$LOCALAI_DEFAULT_DIR"
  else
    printf '%s\n' "$SCRIPT_DIR"
  fi
}

resolve_llama_swap_paths() {
  if [ -z "${LLAMA_SWAP_INSTALL_PATH:-}" ] || [ "$LLAMA_SWAP_INSTALL_PATH" = "/usr/local/bin/llama-swap" ]; then
    LLAMA_SWAP_INSTALL_PATH="$BIN_DIR/llama-swap"
  fi
  LLAMA_SWAP_BIN="${LLAMA_SWAP_BIN:-$LLAMA_SWAP_INSTALL_PATH}"
}

source_localai_lib() {
  local name="$1"
  local candidate

  for candidate in "$SCRIPT_DIR/lib/$name" "$SCRIPT_DIR/../lib/$name"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: $name" >&2
  exit 1
}

api_base_url_for_port_file() {
  local port_file="$1"
  local port

  port="$([ -f "$port_file" ] && cat "$port_file" || printf '%s' "$LOCALAI_DEFAULT_PORT")"
  printf 'http://%s:%s' "$LOCALAI_LISTEN_HOST" "$port"
}

port_is_listening() {
  local port="$1"
  local port_hex

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return "$?"
  fi

  port_hex="$(printf '%04X' "$port")"
  awk -v port="$port_hex" '
    $4 == "0A" {
      n = split($2, address, ":")
      if (toupper(address[n]) == port) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

system_ram_bytes() {
  if [ -n "${LOCALAI_SUGGEST_RAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_RAM_BYTES"
    return 0
  fi

  awk '/MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo 2>/dev/null || printf '0\n'
}

gpu_vram_bytes() {
  local mib bytes candidate max_bytes=0

  if [ -n "${LOCALAI_SUGGEST_VRAM_BYTES:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_VRAM_BYTES"
    return 0
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk 'NR == 1 {print int($1); exit}')"
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi

  if command -v rocm-smi >/dev/null 2>&1; then
    bytes="$(rocm-smi --showmeminfo vram 2>/dev/null | awk '/Total Memory.*\(B\)/ {print int($NF); exit}')"
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$bytes"
      return 0
    fi
  fi

  for candidate in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -r "$candidate" ] || continue
    bytes="$(cat "$candidate" 2>/dev/null || printf '0')"
    if [ -n "$bytes" ] && [ "$bytes" -gt "$max_bytes" ] 2>/dev/null; then
      max_bytes="$bytes"
    fi
  done
  if [ "$max_bytes" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$max_bytes"
    return 0
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    mib="$(vulkaninfo 2>/dev/null | awk '
      /heap [0-9]+:/ && /size =/ {
        value = $0
        sub(/^.*size = /, "", value)
        split(value, parts, " ")
        amount = parts[1] + 0
        unit = parts[2]
        if (unit ~ /GiB/) amount *= 1024
        if (unit ~ /KiB/) amount /= 1024
        if (amount > max) max = amount
      }
      END { if (max > 0) print int(max) }
    ')"
    if [ -n "$mib" ] && [ "$mib" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$((mib * 1024 * 1024))"
      return 0
    fi
  fi

  printf '0\n'
}

installed_backend() {
  if [ -n "${LOCALAI_SUGGEST_BACKEND:-}" ]; then
    printf '%s\n' "$LOCALAI_SUGGEST_BACKEND"
  elif [ -f "$CONF_DIR/$LOCALAI_BACKEND_FILE" ]; then
    cat "$CONF_DIR/$LOCALAI_BACKEND_FILE"
  else
    printf '%s\n' "${LLAMA_CPP_BACKEND:-$LOCALAI_DEFAULT_BACKEND}"
  fi
}

backend_uses_gpu_layers() {
  case "$1" in
    cpu) return 1 ;;
    *) return 0 ;;
  esac
}

# compute_model_runtime_defaults: prints "ctx\tgpu_layers\tflash\tcache_k\tcache_v"
# for a model given its size, detected RAM/VRAM, backend, and whether the
# installed llama-server supports '-ngl auto' (5th arg; defaults to 1/yes).
# gpu_layers is empty when the backend doesn't use the GPU, or when 'auto'
# isn't supported, so callers fall back to their own configured default.
#
# gpu_layers uses llama-server's own 'auto' fit mode (its default since it
# gained free-VRAM-aware layer fitting) rather than a byte-count guess here:
# forcing a specific number (e.g. via a "does it fit" heuristic) disables
# llama.cpp's own fit-to-free-memory logic and can OOM on models that would
# otherwise have partially offloaded successfully. Older pinned llama.cpp
# builds may predate 'auto', hence the capability flag.
compute_model_runtime_defaults() {
  local model_bytes="$1" ram_bytes="$2" vram_bytes="$3" backend="$4"
  local ngl_auto_supported="${5:-1}"
  # gpu_layers uses "-" rather than an empty string as its not-applicable
  # sentinel: bash's `read` collapses consecutive tab delimiters (tab is
  # "IFS whitespace"), so a genuinely empty field between two tabs silently
  # shifts every field after it over by one for the caller's `read`.
  local ctx=8192 gpu_layers=- flash=0 cache_k=f16 cache_v=f16

  if [ "$ram_bytes" -ge $((96 * 1024 * 1024 * 1024)) ]; then
    ctx=16384
  fi
  if [ "$model_bytes" -ge $((80 * 1024 * 1024 * 1024)) ]; then
    ctx=4096
  fi

  if backend_uses_gpu_layers "$backend"; then
    flash=1
    cache_k=q8_0
    cache_v=q8_0
    [ "$ngl_auto_supported" != "1" ] || gpu_layers=auto
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$ctx" "$gpu_layers" "$flash" "$cache_k" "$cache_v"
}

# llama_server_supports_ngl_auto: checks whether a llama-server binary
# accepts '-ngl auto'/'-ngl all' (added once llama.cpp gained free-VRAM-aware
# layer fitting). Older pinned releases (see LLAMA_CPP_VERSION) may not.
llama_server_supports_ngl_auto() {
  local bin="$1"

  [ -x "$bin" ] || return 1
  "$bin" --help 2>&1 | grep -A1 -- '--n-gpu-layers N' | grep -q "'auto'"
}

model_is_embedding_name() {
  local model="${1,,}"

  case "$model" in
    *qwen3*embedding*|*embedding*|*embed*|*bge*) return 0 ;;
    e5-*|*[-_.]e5[-_.]*|*[-_.]e5) return 0 ;;
    *) return 1 ;;
  esac
}

gguf_split_parts() {
  local filename="$1"

  [[ "$filename" =~ ^(.+)-([0-9]+)-of-([0-9]+)\.gguf$ ]]
}

gguf_split_prefix() {
  local filename="$1"

  if gguf_split_parts "$filename"; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

gguf_split_index() {
  local filename="$1"

  if gguf_split_parts "$filename"; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

gguf_split_total() {
  local filename="$1"

  if gguf_split_parts "$filename"; then
    printf '%s\n' "${BASH_REMATCH[3]}"
  fi
}

gguf_split_is_primary() {
  local filename="$1"
  local index

  index="$(gguf_split_index "$filename")"
  [ -n "$index" ] && [ "$((10#$index))" -eq 1 ]
}

gguf_primary_model_name() {
  local filename="$1"
  local prefix

  prefix="$(gguf_split_prefix "$filename")"
  if [ -n "$prefix" ]; then
    printf '%s\n' "$prefix"
  else
    printf '%s\n' "${filename%.gguf}"
  fi
}

gguf_model_file_is_primary() {
  local filename="$1"

  if gguf_split_parts "$filename"; then
    gguf_split_is_primary "$filename"
    return "$?"
  fi

  return 0
}

gguf_model_file_is_mmproj() {
  local filename="${1,,}"

  [[ "$filename" == mmproj*.gguf ]]
}

gguf_model_file_is_noncanonical_split_fragment() {
  local filename="${1,,}"

  gguf_split_parts "$filename" && return 1
  if [[ "$filename" =~ [-_.][0-9]+[-_.]?of[-_.]?[0-9]+ ]]; then
    return 0
  fi
  if [[ "$filename" =~ (^|[-_.])(part|shard|split)[-_.]?[0-9]+([-_.]|$) ]]; then
    return 0
  fi

  return 1
}

gguf_warn_noncanonical_split_fragment() {
  local path="$1"

  echo "Warning: $path looks like a split GGUF fragment but does not match canonical llama.cpp split naming (*-00001-of-000NN.gguf)." >&2
  echo "         Rename the shards to canonical names, keep them together, or merge them with: llama-gguf-split --merge FIRST_SHARD.gguf OUTPUT.gguf" >&2
}

gguf_warn_missing_split_shards() {
  local path="$1"
  local dir filename prefix index total width i shard

  dir="$(dirname "$path")"
  filename="$(basename "$path")"
  gguf_split_parts "$filename" || return 0
  index="${BASH_REMATCH[2]}"
  [ "$((10#$index))" -eq 1 ] || return 0
  prefix="${BASH_REMATCH[1]}"
  total="${BASH_REMATCH[3]}"
  width="${#total}"

  for ((i = 1; i <= 10#$total; i++)); do
    shard="$(printf "%s-%0${width}d-of-%s.gguf" "$prefix" "$i" "$total")"
    if [ ! -f "$dir/$shard" ]; then
      echo "Warning: split GGUF is missing shard: $dir/$shard" >&2
    fi
  done
}

localai_model_entries() {
  local models_dir="$1"
  local rel dir filename id
  local -a entries=()
  local -A primary_counts=()

  [ -d "$models_dir" ] || return 0

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    filename="${rel##*/}"
    gguf_model_file_is_mmproj "$filename" && continue
    if gguf_model_file_is_noncanonical_split_fragment "$filename"; then
      gguf_warn_noncanonical_split_fragment "$models_dir/$rel"
      continue
    fi
    gguf_model_file_is_primary "$filename" || continue
    entries+=("$rel")
    dir="${rel%/*}"
    [ "$dir" = "$rel" ] && dir="."
    primary_counts["$dir"]=$(( ${primary_counts["$dir"]:-0} + 1 ))
  done < <(find "$models_dir" -mindepth 1 -maxdepth 2 -type f -name '*.gguf' -printf '%P\n' | sort)

  for rel in "${entries[@]}"; do
    filename="${rel##*/}"
    dir="${rel%/*}"
    [ "$dir" = "$rel" ] && dir="."

    if [ "$dir" != "." ] && [ "${primary_counts["$dir"]}" -eq 1 ]; then
      id="$dir"
    elif [ "$dir" != "." ]; then
      id="$dir/$(gguf_primary_model_name "$filename")"
      echo "Warning: model folder contains multiple GGUF model entries: $models_dir/$dir" >&2
    else
      id="$(gguf_primary_model_name "$filename")"
    fi

    gguf_warn_missing_split_shards "$models_dir/$rel"
    printf '%s\t%s\t%s\n' "$id" "$rel" "$models_dir/$rel"
  done

  return 0
}

localai_has_model_entries() {
  local models_dir="$1"
  local rel filename

  [ -d "$models_dir" ] || return 1

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    filename="${rel##*/}"
    gguf_model_file_is_mmproj "$filename" && continue
    gguf_model_file_is_noncanonical_split_fragment "$filename" && continue
    if gguf_model_file_is_primary "$filename"; then
      return 0
    fi
  done < <(find "$models_dir" -mindepth 1 -maxdepth 2 -type f -name '*.gguf' -printf '%P\n' | sort)

  return 1
}

localai_model_file_for_id() {
  local models_dir="$1"
  local wanted="$2"
  local id rel path

  while IFS=$'\t' read -r id rel path; do
    [ -n "$id" ] || continue
    if [ "$id" = "$wanted" ] || [ "${rel%.gguf}" = "$wanted" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(localai_model_entries "$models_dir")

  return 1
}

localai_model_bytes() {
  local path="$1"
  local dir filename prefix total width i shard bytes=0 shard_bytes

  filename="$(basename "$path")"
  dir="$(dirname "$path")"
  if gguf_split_parts "$filename"; then
    prefix="${BASH_REMATCH[1]}"
    total="${BASH_REMATCH[3]}"
    width="${#total}"
    for ((i = 1; i <= 10#$total; i++)); do
      shard="$(printf "%s-%0${width}d-of-%s.gguf" "$prefix" "$i" "$total")"
      if [ -f "$dir/$shard" ]; then
        shard_bytes="$(stat -c '%s' "$dir/$shard" 2>/dev/null || printf '0')"
        bytes=$((bytes + shard_bytes))
      fi
    done
  else
    bytes="$(stat -c '%s' "$path" 2>/dev/null || printf '0')"
  fi

  printf '%s\n' "$bytes"
}

format_bytes_gib() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN { printf "%.1f GiB", bytes / 1024 / 1024 / 1024 }'
}

process_start_time() {
  local pid="$1"

  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

pid_file_matches_process() {
  local pid_file="$1"
  local start_file="$2"
  local pid recorded_start current_start

  [ -f "$pid_file" ] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -f "$start_file" ]; then
    recorded_start="$(<"$start_file")"
    current_start="$(process_start_time "$pid")"
    [ -n "$current_start" ] && [ "$recorded_start" = "$current_start" ] || return 1
  fi

  return 0
}

# --- Terminal color helpers (used by `localai key` for readable output) ---

# use_color: 1 when stdout is a terminal and NO_COLOR is unset, same check
# `localai models` already uses for its "loaded" highlighting.
use_color() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

# c CODE TEXT: wraps TEXT in ANSI color CODE when use_color, else passes it
# through unchanged. CODE is a bare SGR number, e.g. 32 for green.
c() {
  local code="$1" text="$2"

  if use_color; then
    printf '\033[%sm%s\033[0m' "$code" "$text"
  else
    printf '%s' "$text"
  fi
}

# --- API key registry (`localai key ...`) ---
#
# Registry file format: one `version\t1` header line, then one line per key:
#   id\tname\tcreated_at\tstatus\tsecret
# `secret` is redacted to "-" once a key is revoked; "-" is this project's
# existing not-applicable sentinel (see compute_model_runtime_defaults).

API_KEY_ID_RE='^[a-f0-9]{12}$'
API_KEY_SECRET_RE='^sk-localai-[0-9a-f]{64}$'
API_KEY_NAME_RE='^[A-Za-z0-9 ._-]{1,64}$'
API_KEY_TIMESTAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

api_key_registry_path() {
  printf '%s\n' "$CONF_DIR/$LOCALAI_API_KEY_FILE"
}

api_key_validate_name() {
  [[ "$1" =~ $API_KEY_NAME_RE ]]
}

# api_key_generate_secret: sk-localai- followed by 256 bits of randomness
# as lowercase hex, from a cryptographic source. Never $RANDOM/timestamps.
api_key_generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'sk-localai-%s\n' "$(openssl rand -hex 32)"
  elif [ -r /dev/urandom ]; then
    printf 'sk-localai-%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    return 1
  fi
}

# api_key_generate_id: a short, display-safe, non-secret identifier derived
# from the secret. Knowing the id does not help recover the secret.
api_key_generate_id() {
  printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 12)}'
}

# api_key_mask: "sk-localai-" + first 4 hex chars + "..." + last 4 hex
# chars. Never enough to reconstruct or narrow down the real secret.
api_key_mask() {
  local secret="$1"

  printf '%s...%s\n' "${secret:0:15}" "${secret: -4}"
}

# api_key_registry_validate FILE: fails closed on any structural problem
# (bad header, bad field, unknown status, duplicate id) so a corrupted
# registry can never be silently treated as "zero keys configured".
api_key_registry_validate() {
  local file="$1"
  local line n=0 id name created status secret
  local -A seen_ids=()

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      [ "$line" = "$(printf 'version\t1')" ] ||
        { echo "Error: unsupported or missing version header in $file" >&2; return 1; }
      continue
    fi

    IFS=$'\t' read -r id name created status secret <<<"$line"

    [[ "$id" =~ $API_KEY_ID_RE ]] ||
      { echo "Error: malformed key id in $file (line $n)" >&2; return 1; }
    [ -z "${seen_ids[$id]+x}" ] ||
      { echo "Error: duplicate key id in $file (line $n)" >&2; return 1; }
    seen_ids["$id"]=1
    api_key_validate_name "$name" ||
      { echo "Error: malformed key name in $file (line $n)" >&2; return 1; }
    [[ "$created" =~ $API_KEY_TIMESTAMP_RE ]] ||
      { echo "Error: malformed timestamp in $file (line $n)" >&2; return 1; }

    case "$status" in
      active)
        [[ "$secret" =~ $API_KEY_SECRET_RE ]] ||
          { echo "Error: malformed secret in $file (line $n)" >&2; return 1; }
        ;;
      revoked)
        [ "$secret" = "-" ] ||
          { echo "Error: revoked key must have a redacted secret in $file (line $n)" >&2; return 1; }
        ;;
      *)
        echo "Error: unknown key status '$status' in $file (line $n)" >&2
        return 1
        ;;
    esac
  done < "$file"
}

# api_key_registry_rows FILE: prints id/name/created/status/secret for every
# key after the header, unvalidated. Callers that display data should
# validate first; api_key_active_secrets and rebuild-config.sh rely on that.
api_key_registry_rows() {
  local file="$1"
  local line n=0

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    printf '%s\n' "$line"
  done < "$file"
}

# api_auth_curl_args: refreshes the global array AUTH_CURL_ARGS with
# -H "Authorization: Bearer <secret>" when at least one API key is active,
# so the CLI's own requests to llama-swap (models/load/unload/check/start
# health checks/stop's drain) keep working once `localai key create` turns
# on authentication. Empty (no header) when there is no active key.
AUTH_CURL_ARGS=()
api_auth_curl_args() {
  local registry secret

  AUTH_CURL_ARGS=()
  registry="$(api_key_registry_path)"
  [ -f "$registry" ] || return 0
  secret="$(api_key_active_secrets "$registry" | head -n1)"
  [ -n "$secret" ] || return 0
  AUTH_CURL_ARGS=(-H "Authorization: Bearer $secret")
}

api_key_active_secrets() {
  local file="$1"
  local id name created status secret

  while IFS=$'\t' read -r id name created status secret; do
    [ "$status" = active ] || continue
    printf '%s\n' "$secret"
  done < <(api_key_registry_rows "$file")
}

# api_key_registry_write_atomic FILE CONTENT: temp file in the same
# directory, mode 0600, atomic rename. CONTENT should already include the
# trailing newline convention (printf adds one).
api_key_registry_write_atomic() {
  local file="$1" content="$2" tmp

  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$file"
}
