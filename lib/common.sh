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
