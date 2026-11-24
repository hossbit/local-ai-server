#!/usr/bin/env bash
set -euo pipefail

LOCALAI_REPO_URL="${LOCALAI_REPO_URL:-https://github.com/hossbit/local-ai-server.git}"
LOCALAI_TARBALL_BASE="${LOCALAI_TARBALL_BASE:-https://github.com/hossbit/local-ai-server/archive}"
LOCALAI_LATEST_API="${LOCALAI_LATEST_API:-https://api.github.com/repos/hossbit/local-ai-server/releases/latest}"
# Install the newest release, never whatever is on main at fetch time. When the
# GitHub API cannot be reached (offline mirror, rate limit) the release this
# script shipped with is used. Override LOCALAI_REF to test another tag/branch.
LOCALAI_REF="${LOCALAI_REF:-latest}"
LOCALAI_FALLBACK_REF="${LOCALAI_FALLBACK_REF:-v1.10.0}"

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
    refs/tags/*|refs/heads/*)
      printf '%s/%s.tar.gz\n' "$LOCALAI_TARBALL_BASE" "$LOCALAI_REF"
      ;;
    v[0-9]*)
      printf '%s/refs/tags/%s.tar.gz\n' "$LOCALAI_TARBALL_BASE" "$LOCALAI_REF"
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
  LOCALAI_REF         Git branch or tag to install. Default: latest release
  LOCALAI_REPO_URL    Git repository URL. Default: https://github.com/hossbit/local-ai-server.git
EOF
}

resolve_ref() {
  local latest_json latest_ref=""

  [ "$LOCALAI_REF" = "latest" ] || return 0

  log "Resolving latest LocalAI release"
  if latest_json="$(curl -fsSL "$LOCALAI_LATEST_API" 2>/dev/null)"; then
    latest_ref="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$latest_json" | head -n 1)"
  fi
  if [ -z "$latest_ref" ]; then
    log "Could not look up the latest release; using ${LOCALAI_FALLBACK_REF}"
    latest_ref="$LOCALAI_FALLBACK_REF"
  fi
  LOCALAI_REF="$latest_ref"
}

# Minimal server and container images often ship without git and tar. Install
# tar with the system package manager (the main installer needs sudo for its
# own packages anyway) instead of stopping before anything happened.
ensure_tar() {
  local sudo_cmd=()

  have tar && return 0
  if [ "$(id -u)" -ne 0 ]; then
    have sudo || fail "tar is required. Install it (for example: dnf install tar), then rerun."
    sudo_cmd=(sudo)
  fi

  log "Installing tar, which this installer needs"
  if have apt-get; then
    "${sudo_cmd[@]}" apt-get install -y tar
  elif have dnf; then
    "${sudo_cmd[@]}" dnf install -y tar
  elif have yum; then
    "${sudo_cmd[@]}" yum install -y tar
  elif have zypper; then
    "${sudo_cmd[@]}" zypper --non-interactive install tar
  else
    fail "tar is required. Install it with your package manager, then rerun."
  fi
  have tar || fail "tar is still missing. Install it with your package manager, then rerun."
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

resolve_ref
log "Installing LocalAI from ${LOCALAI_REPO_URL} (${LOCALAI_REF})"

if have git; then
  clone_ref="${LOCALAI_REF#refs/heads/}"
  clone_ref="${clone_ref#refs/tags/}"
  git clone --depth 1 --branch "$clone_ref" "$LOCALAI_REPO_URL" "$source_dir"
else
  ensure_tar
  archive_file="$tmp_dir/localai.tar.gz"
  curl -fsSL "$(archive_url)" -o "$archive_file"
  mkdir -p "$source_dir"
  tar -xzf "$archive_file" --strip-components=1 -C "$source_dir"
fi

[[ -x "$source_dir/install-local-ai.sh" ]] || fail "Installer not found: $source_dir/install-local-ai.sh"

bash "$source_dir/install-local-ai.sh" "$@"

log "Done. Try: localai status"
