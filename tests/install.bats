#!/usr/bin/env bats
#
# install_llama_cpp_release_dir / activate_llama_cpp_backend: the shared
# multi-backend storage layout ($BIN_DIR/llama.cpp.d/<backend>, with
# $BIN_DIR/llama.cpp as a symlink to whichever one is active).

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT_DIR="$REPO_DIR"
  # shellcheck source=../lib/common.sh
  source "$REPO_DIR/lib/common.sh"
  # shellcheck source=../lib/install.sh
  source "$REPO_DIR/lib/install.sh"

  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  CONF_DIR="$BATS_TEST_TMPDIR/conf"
  TMP_DIR="$BATS_TEST_TMPDIR/tmp"
  LOCALAI_BACKEND_FILE="llama-cpp-backend"
  mkdir -p "$BIN_DIR" "$CONF_DIR" "$TMP_DIR"

  log() { :; }
  fail() {
    echo "Error: $*" >&2
    return 1
  }
}

make_release_dir() {
  local dir="$1" marker="$2"
  mkdir -p "$dir"
  printf '%s' "$marker" > "$dir/marker"
  : > "$dir/llama-server"
  chmod +x "$dir/llama-server"
}

# --- llama_cpp_backend_version ---

@test "llama_cpp_backend_version sets LD_LIBRARY_PATH so a binary needing its own sibling libs still reports its version" {
  # Reproduces a real bug: querying a backend's version by running its raw
  # binary directly (bypassing the LD_LIBRARY_PATH-setting wrapper script)
  # silently looked like "not installed" for a locally-built binary (e.g.
  # CUDA) that has no rpath baked in, even though upstream's prebuilt
  # releases happened to keep working without it.
  local dir="$BIN_DIR/llama.cpp.d/cuda"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<EOF
#!/usr/bin/env bash
case ":\${LD_LIBRARY_PATH:-}:" in
  *":$dir:"*) echo "version: b1234" ;;
  *) echo "error while loading shared libraries" >&2; exit 127 ;;
esac
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_backend_version "cuda"
  [ "$status" -eq 0 ]
  [ "$output" = "b1234" ]
}

@test "llama_cpp_backend_version prints nothing for a backend that was never installed" {
  run llama_cpp_backend_version "nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "llama_cpp_backend_version extracts the real build number from the new semantic-version --version format" {
  # Reproduces a real bug: llama.cpp's own `--version` output changed
  # format alongside the stable/bleeding-edge release split -- it now
  # prints "version: 0.2.0-dev (build 10603, commit ...)" instead of the
  # old "version: 10252 (hash)", so unconditionally taking $2 started
  # returning the semantic version string instead of the build number.
  # That never matches a resolved b[NUM] tag in llama_cpp_versions_match,
  # so `localai update` silently redownloaded and reinstalled an
  # already-current backend on every single run.
  local dir="$BIN_DIR/llama.cpp.d/vulkan"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 0.2.0-dev (build 10603, commit c060ca974)"
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_backend_version "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "10603" ]
}

@test "llama_cpp_backend_version still extracts the build number from the old --version format" {
  local dir="$BIN_DIR/llama.cpp.d/vulkan"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 10252 (fe2adf0e7)"
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_backend_version "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "10252" ]
}

# --- llama_cpp_display_version ---

make_active_llama_server() {
  local raw="$1"
  cat > "$BIN_DIR/llama-server" <<EOF
#!/usr/bin/env bash
echo "$raw"
EOF
  chmod +x "$BIN_DIR/llama-server"
}

@test "llama_cpp_display_version passes non-cuda output through unchanged" {
  make_active_llama_server "version: 10252 (fe2adf0e7)"

  run llama_cpp_display_version "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "version: 10252 (fe2adf0e7)" ]
}

@test "llama_cpp_display_version skips log lines and picks the version line" {
  # Reproduces a real bug: llama-server --version writes initialization log
  # lines to stderr (e.g. "I srv  llama_server: initializing ..."), which
  # get merged into stdout via 2>&1. Taking the first line blindly captured
  # the log message instead of the actual version line.
  cat > "$BIN_DIR/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "I srv  llama_server: initializing ..." >&2
echo "version: 10252 (fe2adf0e7)"
EOF
  chmod +x "$BIN_DIR/llama-server"

  run llama_cpp_display_version "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "version: 10252 (fe2adf0e7)" ]
}

@test "llama_cpp_backend_display_version skips log lines and picks the version line" {
  local dir="$BIN_DIR/llama.cpp.d/vulkan"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "I srv  llama_server: initializing ..." >&2
echo "version: 10252 (fe2adf0e7)"
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_backend_display_version "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "version: 10252 (fe2adf0e7)" ]
}

@test "llama_cpp_display_version substitutes the real build number for cuda" {
  # Reproduces a real bug: a shallow-cloned CUDA build self-reports "version:
  # 1" (llama.cpp computes that number via 'git rev-list --count', which
  # only sees the one commit `git clone --depth 1` fetched) regardless of
  # which revision it actually is -- the recorded build revision is the
  # trustworthy source instead, and only the build number should be
  # replaced, not the commit hash.
  make_active_llama_server "version: 1 (fe2adf0)"
  cuda_installed_revision() { echo "b10252"; }

  run llama_cpp_display_version "cuda"
  [ "$status" -eq 0 ]
  [ "$output" = "version: 10252 (fe2adf0)" ]
}

@test "llama_cpp_display_version falls back to raw output when no cuda revision is recorded" {
  make_active_llama_server "version: 1 (fe2adf0)"
  cuda_installed_revision() { :; }

  run llama_cpp_display_version "cuda"
  [ "$status" -eq 0 ]
  [ "$output" = "version: 1 (fe2adf0)" ]
}

# --- llama_cpp_display_tag ---

@test "llama_cpp_display_tag shows the canonical b[build] tag for a prebuilt backend" {
  # `localai version` should answer "which version is installed" with the
  # build tag the updater compares against (b11223), not the raw
  # "version: 0.5.0-dev (build 11223, ...)" line whose leading semantic
  # version is upstream's cosmetic label.
  local dir="$BIN_DIR/llama.cpp.d/vulkan"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 0.5.0-dev (build 11223, commit 4da633776)"
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_display_tag "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "b11223" ]
}

@test "llama_cpp_display_tag still tags an old-format build number with b" {
  local dir="$BIN_DIR/llama.cpp.d/vulkan"
  mkdir -p "$dir"
  cat > "$dir/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 10252 (fe2adf0e7)"
EOF
  chmod +x "$dir/llama-server"

  run llama_cpp_display_tag "vulkan"
  [ "$status" -eq 0 ]
  [ "$output" = "b10252" ]
}

@test "llama_cpp_display_tag prints nothing for a backend that was never installed" {
  run llama_cpp_display_tag "nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "llama_cpp_display_tag prints cuda's recorded b[build] revision unchanged" {
  cuda_installed_revision() { echo "b10252"; }

  run llama_cpp_display_tag "cuda"
  [ "$status" -eq 0 ]
  [ "$output" = "b10252" ]
}

@test "llama_cpp_display_tag keeps a cuda stable vX.Y.Z pin as-is instead of mislabeling it b[build]" {
  # cuda records the exact resolved tag, which may be either release family;
  # blindly prefixing b would turn a stable pin into the bogus "bv0.5.0".
  cuda_installed_revision() { echo "v0.5.0"; }

  run llama_cpp_display_tag "cuda"
  [ "$status" -eq 0 ]
  [ "$output" = "v0.5.0" ]
}

@test "install_llama_cpp_release_dir stores the backend under llama.cpp.d and symlinks llama.cpp to it" {
  LLAMA_CPP_BACKEND="vulkan"
  make_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "vulkan-build"

  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "$TMP_DIR"

  [ -d "$BIN_DIR/llama.cpp.d/vulkan" ]
  [ -x "$BIN_DIR/llama.cpp.d/vulkan/llama-server" ]
  [ -L "$BIN_DIR/llama.cpp" ]
  [ "$(readlink "$BIN_DIR/llama.cpp")" = "llama.cpp.d/vulkan" ]
  [ "$(cat "$BIN_DIR/llama.cpp/marker")" = "vulkan-build" ]
  [ -x "$BIN_DIR/llama-server" ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "vulkan" ]
}

@test "activate_llama_cpp_backend migrates a pre-existing real llama.cpp directory instead of nesting inside it" {
  # Reproduces a real bug: on the very first install/update after switching
  # to this layout, $BIN_DIR/llama.cpp is still a real directory (the old,
  # pre-multi-backend release dir) rather than a symlink. `ln -sfn` cannot
  # replace a real directory -- it would silently create the new symlink
  # *inside* it (as $BIN_DIR/llama.cpp/cuda) instead of replacing
  # $BIN_DIR/llama.cpp itself.
  mkdir -p "$BIN_DIR/llama.cpp"
  : > "$BIN_DIR/llama.cpp/llama-server"
  chmod +x "$BIN_DIR/llama.cpp/llama-server"

  mkdir -p "$BIN_DIR/llama.cpp.d/cuda"
  : > "$BIN_DIR/llama.cpp.d/cuda/llama-server"
  chmod +x "$BIN_DIR/llama.cpp.d/cuda/llama-server"

  LLAMA_CPP_BACKEND="cuda"
  activate_llama_cpp_backend

  [ -L "$BIN_DIR/llama.cpp" ]
  [ "$(readlink "$BIN_DIR/llama.cpp")" = "llama.cpp.d/cuda" ]
  [ ! -e "$BIN_DIR/llama.cpp/cuda" ]
}

@test "installing a second backend does not delete the first backend's slot" {
  LLAMA_CPP_BACKEND="vulkan"
  make_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "vulkan-build"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "$TMP_DIR"

  LLAMA_CPP_BACKEND="cuda"
  make_release_dir "$BATS_TEST_TMPDIR/release-cuda" "cuda-build"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-cuda" "$TMP_DIR"

  # Both slots still exist...
  [ -x "$BIN_DIR/llama.cpp.d/vulkan/llama-server" ]
  [ -x "$BIN_DIR/llama.cpp.d/cuda/llama-server" ]
  # ...but cuda, installed most recently, is the active one.
  [ "$(readlink "$BIN_DIR/llama.cpp")" = "llama.cpp.d/cuda" ]
  [ "$(cat "$BIN_DIR/llama.cpp/marker")" = "cuda-build" ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "cuda" ]
}

@test "activate_llama_cpp_backend repoints an already-installed slot without reinstalling anything" {
  LLAMA_CPP_BACKEND="vulkan"
  make_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "vulkan-build"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-vulkan" "$TMP_DIR"

  LLAMA_CPP_BACKEND="cuda"
  make_release_dir "$BATS_TEST_TMPDIR/release-cuda" "cuda-build"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-cuda" "$TMP_DIR"

  # Switch back to vulkan the way `localai switch` does: no reinstall, just
  # repoint.
  LLAMA_CPP_BACKEND="vulkan"
  activate_llama_cpp_backend

  [ "$(readlink "$BIN_DIR/llama.cpp")" = "llama.cpp.d/vulkan" ]
  [ "$(cat "$BIN_DIR/llama.cpp/marker")" = "vulkan-build" ]
  [ "$(cat "$CONF_DIR/$LOCALAI_BACKEND_FILE")" = "vulkan" ]
  # cuda's slot is untouched.
  [ "$(cat "$BIN_DIR/llama.cpp.d/cuda/marker")" = "cuda-build" ]
}

@test "reinstalling the same backend replaces only that backend's slot" {
  LLAMA_CPP_BACKEND="vulkan"
  make_release_dir "$BATS_TEST_TMPDIR/release-v1" "vulkan-v1"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-v1" "$TMP_DIR"

  make_release_dir "$BATS_TEST_TMPDIR/release-v2" "vulkan-v2"
  install_llama_cpp_release_dir "$BATS_TEST_TMPDIR/release-v2" "$TMP_DIR"

  [ "$(cat "$BIN_DIR/llama.cpp/marker")" = "vulkan-v2" ]
}

# --- cleanup_bin_artifacts: regression guard for both install-local-ai.sh
# and update-local-ai.sh (duplicated one-liners, not a lib/*.sh function) --
# must never sweep up llama.cpp.d along with genuinely stray directories.

@test "cleanup_bin_artifacts preserves llama.cpp.d in both install-local-ai.sh and update-local-ai.sh" {
  local script
  for script in install-local-ai.sh update-local-ai.sh; do
    run grep -A3 '^cleanup_bin_artifacts() {' "$REPO_DIR/$script"
    [ "$status" -eq 0 ]
    [[ "$output" == *'! -name llama.cpp.d'* ]]
  done
}

# --- backend_dependency_hint: a prebuilt backend's binary failing to run is
# almost always a missing vendor runtime, not a LocalAI bug -- these must
# name what's actually missing and where to get it, never attempt to
# install it (that's cuda_toolkit_install_hint's territory in lib/cuda.sh,
# same reasoning: large vendor-specific stacks that can conflict with a
# driver already on the system).

@test "backend_dependency_hint gives specific guidance for every non-cpu prebuilt backend" {
  local backend
  for backend in vulkan rocm openvino sycl-fp16 sycl-fp32; do
    run backend_dependency_hint "$backend"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "backend_dependency_hint returns non-zero for a backend with no specific guidance" {
  run backend_dependency_hint cpu
  [ "$status" -ne 0 ]

  run backend_dependency_hint nonexistent
  [ "$status" -ne 0 ]
}

# --- resolve_llama_cpp_latest_json: llama.cpp now publishes both b[NUM]
# bleeding-edge and vX.Y.Z stable releases. GET /releases/latest only ever
# returns the newest non-prerelease release, which since the stable channel
# launched means it always resolves to a vX.Y.Z tag -- every b[NUM] release
# is marked prerelease. Bleeding-edge tracking therefore can't use that
# endpoint at all; it has to walk the plain releases list instead.

@test "resolve_llama_cpp_latest_json (bleeding-edge) picks the newest b[NUM] release, ignoring interleaved stable tags" {
  github_api_get() {
    case "$1" in
      *"/releases?per_page="*)
        cat <<'JSON'
[
  {"tag_name": "v0.2.0", "prerelease": false, "assets": []},
  {"tag_name": "b10603", "prerelease": true, "assets": []},
  {"tag_name": "b10599", "prerelease": true, "assets": []}
]
JSON
        ;;
      *) echo "unexpected call: $1" >&2; return 1 ;;
    esac
  }
  LLAMA_CPP_CHANNEL="bleeding-edge"
  LLAMA_CPP_RELEASES_API="https://api.example/releases"
  LLAMA_CPP_RELEASES_PAGE_SIZE="20"

  run resolve_llama_cpp_latest_json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tag_name' <<<"$output")" = "b10603" ]
}

@test "resolve_llama_cpp_latest_json (bleeding-edge) fails clearly when no b[NUM] release is found" {
  # fail() from setup() only `return`s (so tests calling functions directly,
  # without `run`, don't kill the whole bats process) -- but that means code
  # after a bare `fail "..."` call keeps running, same as it would with any
  # non-exiting fail(). Only `run`, which forks a real subshell, makes exit
  # safe here, so this test needs its own fail() that actually exits, the
  # same way every real caller's fail() does.
  fail() { echo "Error: $*" >&2; exit 1; }
  github_api_get() { echo '[{"tag_name": "v0.2.0", "prerelease": false, "assets": []}]'; }
  LLAMA_CPP_CHANNEL="bleeding-edge"
  LLAMA_CPP_RELEASES_API="https://api.example/releases"
  LLAMA_CPP_RELEASES_PAGE_SIZE="20"

  run resolve_llama_cpp_latest_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"no bleeding-edge"* ]]
}

@test "resolve_llama_cpp_latest_json (stable) fetches /releases/latest directly and returns it unchanged" {
  github_api_get() {
    case "$1" in
      "https://api.example/releases/latest")
        echo '{"tag_name": "v0.2.0", "assets": [{"name": "nightly-tag.txt"}]}'
        ;;
      *) echo "unexpected call: $1" >&2; return 1 ;;
    esac
  }
  LLAMA_CPP_CHANNEL="stable"
  LLAMA_CPP_LATEST_API="https://api.example/releases/latest"

  run resolve_llama_cpp_latest_json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tag_name' <<<"$output")" = "v0.2.0" ]
}

@test "resolve_llama_cpp_latest_json rejects an unsupported channel" {
  LLAMA_CPP_CHANNEL="nightly"

  run resolve_llama_cpp_latest_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported LLAMA_CPP_CHANNEL"* ]]
}

# --- resolve_llama_cpp_binary_json: a stable vX.Y.Z release ships no
# backend binaries of its own, only a nightly-tag.txt asset naming the
# b[NUM] release actually built from that point -- this must be followed
# to reach real assets. A b[NUM] release already has its own assets and
# must pass through unchanged.

@test "resolve_llama_cpp_binary_json passes a release through unchanged when it has no nightly-tag.txt" {
  local json='{"tag_name":"b10603","assets":[{"name":"llama-b10603-bin-ubuntu-vulkan-x64.tar.gz","browser_download_url":"https://example/vulkan.tar.gz"}]}'

  run resolve_llama_cpp_binary_json "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "$json" ]
}

@test "resolve_llama_cpp_binary_json follows nightly-tag.txt to the release that actually has binaries" {
  local stable_json='{"tag_name":"v0.2.0","assets":[{"name":"nightly-tag.txt","browser_download_url":"https://example/nightly-tag.txt"}]}'
  LLAMA_CPP_NIGHTLY_TAG_ASSET="nightly-tag.txt"
  curl() { echo "b10566"; }
  github_api_get() {
    case "$1" in
      *"/releases/tags/b10566")
        echo '{"tag_name":"b10566","assets":[{"name":"llama-b10566-bin-ubuntu-vulkan-x64.tar.gz"}]}'
        ;;
      *) echo "unexpected call: $1" >&2; return 1 ;;
    esac
  }

  run resolve_llama_cpp_binary_json "$stable_json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tag_name' <<<"$output")" = "b10566" ]
}

@test "resolve_llama_cpp_binary_json fails clearly on an empty nightly-tag.txt" {
  fail() { echo "Error: $*" >&2; exit 1; }
  local stable_json='{"tag_name":"v0.2.0","assets":[{"name":"nightly-tag.txt","browser_download_url":"https://example/nightly-tag.txt"}]}'
  LLAMA_CPP_NIGHTLY_TAG_ASSET="nightly-tag.txt"
  curl() { echo ""; }

  run resolve_llama_cpp_binary_json "$stable_json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

# --- ensure_cli_on_path: the installer's fix for `localai: command not
# found` right after a fresh install -- ~/.profile only loads for login
# shells, so most terminal emulators (which open non-login interactive
# shells sourcing ~/.bashrc/~/.zshrc) never actually picked up the PATH
# addition it already had. Must add it to the file the shell actually
# sources, and must not duplicate the block on repeat runs.

@test "ensure_cli_on_path is a no-op when the directory is already on PATH" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  LOCALAI_USER_BIN_DIR="$HOME/.local/bin"
  PATH="$LOCALAI_USER_BIN_DIR:/usr/bin"
  SHELL="/bin/bash"

  run ensure_cli_on_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$HOME/.bashrc" ]
}

@test "ensure_cli_on_path appends the PATH block to ~/.bashrc for a bash shell" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  LOCALAI_USER_BIN_DIR="$HOME/.local/bin"
  PATH="/usr/bin"
  SHELL="/bin/bash"

  run ensure_cli_on_path
  [ "$status" -eq 2 ]
  [[ "$output" == *"Added $LOCALAI_USER_BIN_DIR to PATH in $HOME/.bashrc"* ]]
  grep -qF "$LOCALAI_USER_BIN_DIR" "$HOME/.bashrc"
}

@test "ensure_cli_on_path picks ~/.zshrc for a zsh shell" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  LOCALAI_USER_BIN_DIR="$HOME/.local/bin"
  PATH="/usr/bin"
  SHELL="/usr/bin/zsh"

  run ensure_cli_on_path
  [ "$status" -eq 2 ]
  grep -qF "$LOCALAI_USER_BIN_DIR" "$HOME/.zshrc"
  [ ! -e "$HOME/.bashrc" ]
}

@test "ensure_cli_on_path does not duplicate the PATH block on a second run" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  LOCALAI_USER_BIN_DIR="$HOME/.local/bin"
  PATH="/usr/bin"
  SHELL="/bin/bash"

  ensure_cli_on_path >/dev/null || true
  local first_content
  first_content="$(cat "$HOME/.bashrc")"

  run ensure_cli_on_path
  [ "$status" -eq 2 ]
  [[ "$output" == *"already references"* ]]
  [ "$(cat "$HOME/.bashrc")" = "$first_content" ]
}

@test "ensure_cli_on_path falls back to a manual note when the rc file isn't writable" {
  HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  touch "$HOME/.bashrc"
  chmod 400 "$HOME/.bashrc"
  LOCALAI_USER_BIN_DIR="$HOME/.local/bin"
  PATH="/usr/bin"
  SHELL="/bin/bash"

  run ensure_cli_on_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't writable"* ]]
  chmod 600 "$HOME/.bashrc"
}

# --- reconnect_shell_on_path: exec-ing a replacement shell can't be
# exercised directly under bats (there's no real controlling terminal in
# the test harness -- [ -t 1 ] is always false for a `run`-captured or
# piped command), but that's exactly the guard that must be verified: it
# should never even attempt the exec in a non-interactive context like this
# one, regardless of what ensure_cli_on_path returned.

@test "reconnect_shell_on_path does nothing when ensure_cli_on_path status was not 2" {
  run reconnect_shell_on_path 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run reconnect_shell_on_path 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconnect_shell_on_path does not attempt exec outside a real terminal, even with status 2" {
  run reconnect_shell_on_path 2
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "library refresh removes retired workspace and preserves custom files" {
  local source_dir="$BATS_TEST_TMPDIR/source"
  local dest_dir="$BATS_TEST_TMPDIR/lib"
  mkdir -p "$source_dir/lib" "$dest_dir" "$CONF_DIR/ui"
  printf '# helper\n' > "$source_dir/lib/helper.sh"
  touch "$dest_dir/ui.html" "$CONF_DIR/ui/index.html" "$CONF_DIR/ui/custom.txt"
  run install_localai_libs "$source_dir" "$dest_dir"
  [ "$status" -eq 0 ]
  [ -f "$dest_dir/helper.sh" ]
  [ ! -e "$dest_dir/ui.html" ]
  [ ! -e "$CONF_DIR/ui/index.html" ]
  [ -f "$CONF_DIR/ui/custom.txt" ]
  rm "$CONF_DIR/ui/custom.txt"
  run install_localai_libs "$source_dir" "$dest_dir"
  [ "$status" -eq 0 ]
  [ ! -d "$CONF_DIR/ui" ]
}
