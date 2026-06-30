#!/usr/bin/env bash
set -euo pipefail

LOCALAI_REPO_URL="${LOCALAI_REPO_URL:-https://github.com/hossbit/local-ai-server.git}"
LOCALAI_TARBALL_BASE="${LOCALAI_TARBALL_BASE:-https://github.com/hossbit/local-ai-server/archive}"
LOCALAI_REF="${LOCALAI_REF:-main}"

log() {
  printf 'localai-install: %s\n' "$*"
}

fail() {
  printf 'localai-install: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

archive_url() {
  case "$LOCALAI_REF" in
    v*|refs/tags/*)
      printf '%s/refs/tags/%s.tar.gz\n' "$LOCALAI_TARBALL_BASE" "${LOCALAI_REF#refs/tags/}"
      ;;
    refs/heads/*)
      printf '%s/%s.tar.gz\n' "$LOCALAI_TARBALL_BASE" "$LOCALAI_REF"
      ;;
    *)
      printf '%s/refs/heads/%s.tar.gz\n' "$LOCALAI_TARBALL_BASE" "$LOCALAI_REF"
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: curl -fsSL https://hossbit.github.io/localai/install.sh | bash

Custom install directory:
  curl -fsSL https://hossbit.github.io/localai/install.sh | LOCALAI_DIR="\$HOME/my-ai" bash

Choose a llama.cpp backend:
  curl -fsSL https://hossbit.github.io/localai/install.sh | LLAMA_CPP_BACKEND=cpu bash

Environment:
  LOCALAI_DIR         Install directory. Default is controlled by the LocalAI installer.
  LLAMA_CPP_BACKEND   llama.cpp backend. Default is controlled by the LocalAI installer.
  LOCALAI_REF         Git branch or tag to install. Default: main
  LOCALAI_REPO_URL    Git repository URL. Default: https://github.com/hossbit/local-ai-server.git
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

have bash || fail "bash is required."
have curl || fail "curl is required."
have mktemp || fail "mktemp is required."

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

source_dir="$tmp_dir/localai-source"

log "Installing LocalAI from ${LOCALAI_REPO_URL} (${LOCALAI_REF})"

if have git; then
  git clone --depth 1 --branch "$LOCALAI_REF" "$LOCALAI_REPO_URL" "$source_dir"
else
  have tar || fail "git or tar is required."
  archive_file="$tmp_dir/localai.tar.gz"
  curl -fsSL "$(archive_url)" -o "$archive_file"
  mkdir -p "$source_dir"
  tar -xzf "$archive_file" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name 'local-ai-server-*' | head -n 1)"
  [[ -n "${extracted:-}" ]] || fail "Could not find extracted LocalAI source directory."
  rm -rf "$source_dir"
  mv "$extracted" "$source_dir"
fi

[[ -x "$source_dir/install-local-ai.sh" ]] || fail "Installer not found: $source_dir/install-local-ai.sh"

bash "$source_dir/install-local-ai.sh" "$@"

log "Done. Try: localai status"
