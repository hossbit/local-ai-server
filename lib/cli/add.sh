# shellcheck shell=bash disable=SC2153,SC2154

add_usage() {
  cat <<'USAGE'
Usage: localai add SOURCE

  localai add /data/model.gguf        Link a local file (not moved or copied)
  localai add /data/model-folder      Link a folder that contains GGUF files
  localai add ORG/REPO                List a Hugging Face repository's GGUF files
  localai add ORG/REPO:Q4_K_M         Download one quantization
  localai add ORG/REPO/FILE.gguf      Download one file

Split models are linked or downloaded complete. Interrupted downloads resume.
Set HF_TOKEN for private or gated repositories.
USAGE
}

add_cmd() {
  local source="${1:-}" path
  case "$source" in -h|--help) add_usage; return ;; esac
  if [ "$#" -ne 1 ] || [ -z "$source" ]; then add_usage >&2; return 2; fi
  mkdir -p "$MODELS_DIR"
  path="$(expand_path "$source")"
  # An existing local path always wins over a Hugging Face name.
  if [ -e "$path" ]; then
    add_local "$(realpath "$path")"
  elif [[ "$source" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*((:[A-Za-z0-9_]+)|(/[A-Za-z0-9._/-]+\.[gG][gG][uU][fF]))?$ ]] &&
    [[ "/$source/" != */../* ]]; then
    add_huggingface "$source"
  else
    fail "not found: $source (use an existing file or folder, or ORG/REPO)"
  fi
  echo "Apply it with: localai reload"
}

add_link() {
  local source="$1" target="$2"
  if [ -e "$target" ] || [ -L "$target" ]; then
    fail "already exists: $target"
  fi
  ln -s -- "$source" "$target"
}

# Shards of one split model must sit in one folder with nothing else.
add_local() {
  local path="$1" name shard prefix total i file width
  name="$(basename "$path")"
  case "$path" in
    "$(realpath "$MODELS_DIR")"/*) echo "Already in the models directory: $path"; return ;;
  esac
  if [ -d "$path" ]; then
    find -L "$path" -maxdepth 1 -type f -iname '*.gguf' -print -quit | grep -q . ||
      fail "no GGUF files in $path"
    add_link "$path" "$MODELS_DIR/$name"
  else
    [[ "${name,,}" == *.gguf ]] || fail "not a GGUF file: $path"
    total="$(gguf_split_total "$name")"
    if [ -n "$total" ]; then
      prefix="$(gguf_split_prefix "$name")"
      width="${#total}"
      local -a shards=()
      for ((i = 1; i <= 10#$total; i++)); do
        printf -v shard "%s-%0${width}d-of-%s.gguf" "$prefix" "$i" "$total"
        file="$(dirname "$path")/$shard"
        [ -f "$file" ] || fail "missing split shard: $file"
        shards+=("$file")
      done
      if [ -e "$MODELS_DIR/$prefix" ] || [ -L "$MODELS_DIR/$prefix" ]; then fail "already exists: $MODELS_DIR/$prefix"; fi
      mkdir "$MODELS_DIR/$prefix"
      for file in "${shards[@]}"; do ln -s -- "$file" "$MODELS_DIR/$prefix/"; done
      name="$prefix"
    else
      add_link "$path" "$MODELS_DIR/$name"
    fi
  fi
  echo "Added $name from $path. Files were not moved or copied."
}

# The token goes through curl's stdin config so it never shows up in `ps`.
add_hf_curl() {
  if [ -n "${HF_TOKEN:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$HF_TOKEN" | curl -K - "$@"
  else
    curl "$@"
  fi
}

add_huggingface() {
  local spec="$1" repo rest quant="" wanted="" json rows selected="" path size sha first dest file free need=0
  for file in curl jq; do command -v "$file" >/dev/null 2>&1 || fail "$file is required to download models"; done
  repo="$(cut -d/ -f1,2 <<<"$spec")"
  if [[ "$repo" == *:* ]]; then
    quant="${repo#*:}"; repo="${repo%%:*}"
  else
    rest="${spec#"$repo"}"; wanted="${rest#/}"
  fi

  json="$(add_hf_curl --max-time 30 -fsSL "$LOCALAI_HF_ENDPOINT/api/models/$repo/tree/main?recursive=true")" ||
    fail "could not read $repo on Hugging Face. Check the name; private or gated repositories need HF_TOKEN."
  rows="$(jq -r '.[] | select(.type == "file")
    | select(.path | test("^[A-Za-z0-9._/-]+\\.gguf$"; "i"))
    | select(.path | test("(^|/)mmproj[^/]*$"; "i") | not)
    | [.path, .size, (.lfs.oid // "-")] | @tsv' <<<"$json")" || fail "unexpected reply from Hugging Face"
  [ -n "$rows" ] || fail "$repo has no GGUF files. Look for a repository whose name ends in -GGUF."

  if [ -n "$wanted" ]; then
    selected="$(awk -F'\t' -v p="$wanted" '$1 == p' <<<"$rows")"
  elif [ -n "$quant" ]; then
    selected="$(awk -F'\t' -v q="${quant,,}" '{ n = tolower($1); sub(/.*\//, "", n); if (n ~ ("(^|[-._])" q "[-.]")) print }' <<<"$rows")"
  elif [ "$(wc -l <<<"$rows")" -eq 1 ]; then
    selected="$rows"
  fi
  if [ -z "$selected" ]; then
    echo "GGUF files in $repo:"
    while IFS=$'\t' read -r path size sha; do
      printf '  %10s  %s\n' "$(format_bytes_gib "$size")" "$path"
    done <<<"$rows"
    [ -z "$wanted$quant" ] || fail "no match for '${wanted:-$quant}' in $repo"
    fail "choose one: localai add $repo:Q4_K_M or localai add $repo/FILE.gguf"
  fi

  # A shard stands for its whole split model; otherwise exactly one file.
  first="$(head -n1 <<<"$selected" | cut -f1)"
  if [ -n "$(gguf_split_total "$(basename "$first")")" ]; then
    local prefix total dir
    prefix="$(gguf_split_prefix "$(basename "$first")")"; total="$(gguf_split_total "$(basename "$first")")"
    dir="$(dirname "$first")"
    local all=""
    all="$(awk -F'\t' -v d="$dir" -v p="$prefix-" -v t="-of-$total." '{ n = $1; b = n; sub(/.*\//, "", b); parent = (n == b) ? "." : substr(n, 1, length(n) - length(b) - 1); if (parent == d && index(b, p) == 1 && index(b, t)) print }' <<<"$rows")"
    [ "$(wc -l <<<"$all")" -eq "$((10#$total))" ] || fail "the split model $prefix is incomplete in $repo"
    if [ -n "$quant" ] && [ "$(wc -l <<<"$selected")" -ne "$((10#$total))" ]; then
      fail "'$quant' matches several models; name one file: localai add $repo/FILE.gguf"
    fi
    selected="$all"
    dest="$MODELS_DIR/$prefix"
  else
    [ "$(wc -l <<<"$selected")" -eq 1 ] || fail "'$quant' matches several files; name one: localai add $repo/FILE.gguf"
    dest="$MODELS_DIR"
  fi

  while IFS=$'\t' read -r path size sha; do
    [ -e "$dest/$(basename "$path")" ] || need=$((need + size))
  done <<<"$selected"
  free="$(df -PB1 "$MODELS_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "$free" =~ ^[0-9]+$ ]] && [ "$free" -lt "$need" ]; then
    fail "not enough disk space: $(format_bytes_gib "$need") needed, $(format_bytes_gib "$free") free in $MODELS_DIR"
  fi

  mkdir -p "$dest"
  while IFS=$'\t' read -r path size sha; do
    file="$dest/$(basename "$path")"
    if [ -e "$file" ]; then echo "Already downloaded: $file"; continue; fi
    echo "Downloading $path ($(format_bytes_gib "$size"))"
    # A complete .part (interrupted before the rename) must not be resumed:
    # the server would answer 416.
    if [ "$(stat -c %s "$file.part" 2>/dev/null || echo 0)" != "$size" ]; then
      add_hf_curl -fL --retry 3 -C - -o "$file.part" "$LOCALAI_HF_ENDPOINT/$repo/resolve/main/$path" ||
        fail "download failed; run the same command to resume"
    fi
    if [ "$sha" != "-" ] && [ "$(sha256sum "$file.part" | awk '{print $1}')" != "$sha" ]; then
      rm -f -- "$file.part"
      fail "checksum mismatch for $path; the download was removed"
    fi
    mv -- "$file.part" "$file"
  done < <(printf '%s\n' "$selected")
  echo "Added $(basename "$first") to $dest"
}
