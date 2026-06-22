#!/usr/bin/env bash
set -Eeuo pipefail

AI_DIR="$HOME/ai"
BIN_DIR="$AI_DIR/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
LLAMA_SWAP_API="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"
START_AFTER_UPDATE=1

if [ "${1:-}" = "--no-start" ]; then
  START_AFTER_UPDATE=0
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--no-start]" >&2
  exit 2
fi

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

for COMMAND in curl jq tar; do
  command -v "$COMMAND" >/dev/null 2>&1 || fail "required command not found: $COMMAND"
done

[ "$(uname -m)" = "x86_64" ] || fail "this updater currently supports x86_64 Linux only"

mkdir -p "$AI_DIR" "$BIN_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$SCRIPT_DIR" != "$AI_DIR" ]; then
  for SCRIPT in start.sh stop.sh rebuild-config.sh update-local-ai.sh; do
    if [ -f "$SCRIPT_DIR/$SCRIPT" ]; then
      install -m755 "$SCRIPT_DIR/$SCRIPT" "$AI_DIR/$SCRIPT"
    fi
  done
fi

log "Fetching release metadata"
LLAMA_CPP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_CPP_API")
LLAMA_SWAP_JSON=$(curl -4 --connect-timeout 10 --max-time 30 -fsSL "$LLAMA_SWAP_API")

LLAMA_CPP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_CPP_JSON")
LLAMA_SWAP_TAG=$(jq -er '.tag_name' <<<"$LLAMA_SWAP_JSON")
LLAMA_CPP_URL=$(jq -er \
  '.assets[] | select(.name | test("ubuntu-vulkan-x64\\.tar\\.gz$")) | .browser_download_url' \
  <<<"$LLAMA_CPP_JSON" | head -n1)
LLAMA_SWAP_URL=$(jq -er \
  '.assets[] | select(.name | test("linux_amd64\\.tar\\.gz$")) | .browser_download_url' \
  <<<"$LLAMA_SWAP_JSON" | head -n1)

[ -n "$LLAMA_CPP_URL" ] || fail "no llama.cpp Ubuntu Vulkan x64 asset found"
[ -n "$LLAMA_SWAP_URL" ] || fail "no llama-swap Linux amd64 asset found"

CURRENT_LLAMA_CPP=$(
  "$BIN_DIR/llama-server" --version 2>&1 |
    awk '/version:/ {print $2; exit}' || true
)
CURRENT_LLAMA_SWAP=$(
  llama-swap --version 2>&1 |
    grep -oE 'v?[0-9]+' |
    head -n1 || true
)

printf 'llama.cpp:  installed=%s latest=%s\n' "${CURRENT_LLAMA_CPP:-none}" "$LLAMA_CPP_TAG"
printf 'llama-swap: installed=%s latest=%s\n' "${CURRENT_LLAMA_SWAP:-none}" "$LLAMA_SWAP_TAG"

NEED_CPP=1
NEED_SWAP=1
if [ -n "$CURRENT_LLAMA_CPP" ]; then
  case "$LLAMA_CPP_TAG" in
    *"$CURRENT_LLAMA_CPP"*) NEED_CPP=0 ;;
  esac
fi
if [ -n "$CURRENT_LLAMA_SWAP" ]; then
  case "$LLAMA_SWAP_TAG" in
    *"${CURRENT_LLAMA_SWAP#v}") NEED_SWAP=0 ;;
  esac
fi

if ((NEED_CPP == 0 && NEED_SWAP == 0)); then
  log "Everything is already up to date"
  exit 0
fi

if [ -x "$AI_DIR/stop.sh" ]; then
  "$AI_DIR/stop.sh"
elif [ -x "$SCRIPT_DIR/stop.sh" ]; then
  "$SCRIPT_DIR/stop.sh"
fi

if ((NEED_CPP)); then
  log "Installing llama.cpp $LLAMA_CPP_TAG"
  mkdir -p "$TMP_DIR/llama.cpp"
  curl -4 -fL --retry 3 -o "$TMP_DIR/llama.cpp.tar.gz" "$LLAMA_CPP_URL"
  tar -xzf "$TMP_DIR/llama.cpp.tar.gz" -C "$TMP_DIR/llama.cpp"

  LLAMA_SERVER_REAL=$(find "$TMP_DIR/llama.cpp" -type f -name llama-server | head -n1)
  [ -n "$LLAMA_SERVER_REAL" ] || fail "llama-server was not found in the downloaded archive"
  LLAMA_DIR=$(dirname "$LLAMA_SERVER_REAL")

  rm -rf "$BIN_DIR/llama.cpp"
  mv "$LLAMA_DIR" "$BIN_DIR/llama.cpp"

  cat > "$TMP_DIR/llama-server" <<EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="$BIN_DIR/llama.cpp:\${LD_LIBRARY_PATH:-}"
exec "$BIN_DIR/llama.cpp/llama-server" "\$@"
EOF
  install -m755 "$TMP_DIR/llama-server" "$BIN_DIR/llama-server"
fi

if ((NEED_SWAP)); then
  log "Installing llama-swap $LLAMA_SWAP_TAG"
  mkdir -p "$TMP_DIR/llama-swap"
  curl -4 -fL --retry 3 -o "$TMP_DIR/llama-swap.tar.gz" "$LLAMA_SWAP_URL"
  tar -xzf "$TMP_DIR/llama-swap.tar.gz" -C "$TMP_DIR/llama-swap"

  LLAMA_SWAP_REAL=$(find "$TMP_DIR/llama-swap" -type f -name llama-swap | head -n1)
  [ -n "$LLAMA_SWAP_REAL" ] || fail "llama-swap was not found in the downloaded archive"
  sudo install -m755 "$LLAMA_SWAP_REAL" /usr/local/bin/llama-swap
fi

if [ "$START_AFTER_UPDATE" -eq 1 ]; then
  if [ -x "$AI_DIR/start.sh" ]; then
    "$AI_DIR/start.sh"
  else
    log "Updated successfully; run the installer to create the service and helper scripts"
  fi
else
  log "Updated successfully"
fi
