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

# resolve_llama_cpp_latest_json: fetches the release JSON that "latest"
# means for $LLAMA_CPP_CHANNEL. GET /releases/latest only ever resolves
# GitHub's own notion of "latest", which now (since llama.cpp started
# publishing non-prerelease vX.Y.Z stable tags) always means the stable
# channel -- every b[NUM] bleeding-edge release is marked prerelease and is
# therefore invisible to that endpoint. Tracking bleeding-edge instead means
# walking the plain releases list and taking the newest b[NUM] entry.
resolve_llama_cpp_latest_json() {
  local channel="${LLAMA_CPP_CHANNEL:-bleeding-edge}"
  local json

  case "$channel" in
    stable)
      github_api_get "$LLAMA_CPP_LATEST_API"
      ;;
    bleeding-edge)
      json="$(github_api_get "${LLAMA_CPP_RELEASES_API}?per_page=${LLAMA_CPP_RELEASES_PAGE_SIZE}")"
      json="$(jq -c '[.[] | select(.tag_name | test("^b[0-9]+$"))][0] // empty' <<<"$json")"
      [ -n "$json" ] || fail "no bleeding-edge (b[NUM]) llama.cpp release found in the last $LLAMA_CPP_RELEASES_PAGE_SIZE releases. Retry, or raise LLAMA_CPP_RELEASES_PAGE_SIZE if upstream published an unusually long run of stable releases."
      printf '%s\n' "$json"
      ;;
    *)
      fail "unsupported LLAMA_CPP_CHANNEL: $channel. Use bleeding-edge or stable."
      ;;
  esac
}

# resolve_llama_cpp_binary_json: given a resolved llama.cpp release JSON,
# returns the release JSON that actually carries backend binaries. Every
# b[NUM] release already does (returned unchanged); a stable vX.Y.Z release
# instead carries a $LLAMA_CPP_NIGHTLY_TAG_ASSET asset naming the b[NUM]
# release built from that same point, which is followed and fetched
# instead. Not used for the cuda backend, which builds from source and can
# check out $json's tag directly regardless of channel.
resolve_llama_cpp_binary_json() {
  local json="$1"
  local nightly_url nightly_tag

  nightly_url="$(release_asset_url "$json" "^${LLAMA_CPP_NIGHTLY_TAG_ASSET}\$")"
  if [ -z "$nightly_url" ]; then
    printf '%s\n' "$json"
    return 0
  fi

  nightly_tag="$(curl -4 -fsSL "$nightly_url")" ||
    fail "failed to download $LLAMA_CPP_NIGHTLY_TAG_ASSET from llama.cpp release $(jq -er '.tag_name' <<<"$json")"
  nightly_tag="$(printf '%s' "$nightly_tag" | tr -d '[:space:]')"
  [ -n "$nightly_tag" ] || fail "empty $LLAMA_CPP_NIGHTLY_TAG_ASSET asset in llama.cpp release $(jq -er '.tag_name' <<<"$json")"

  github_api_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$nightly_tag"
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
      fail "missing sha256 digest for $label release asset.

This usually means you're pinning an older release from before GitHub
started publishing asset digests.

Fix:
  Rerun with LOCALAI_SKIP_DIGEST=1 to install without checksum verification."
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

# backend_dependency_hint: one-line, copy-pasteable next step for a prebuilt
# backend whose downloaded binary didn't actually run -- almost always
# because the vendor runtime/driver stack it needs isn't installed
# (install_system_dependencies only ever installs generic build tooling and
# the Vulkan loader, never a GPU vendor's own runtime). Returns non-zero for
# a backend with no specific guidance (cpu should always run; an unknown
# name), so the caller can fall back to its own generic message. Never
# attempts to install any of these automatically -- same reasoning as
# cuda_toolkit_install_hint (lib/cuda.sh): they're large, vendor-specific
# stacks that can conflict with a driver already on the system.
backend_dependency_hint() {
  local backend="$1"
  case "$backend" in
    vulkan)
      printf 'Fix:\n  Check for a real Vulkan-capable driver -- the loader alone (installed\n  automatically) is not enough: vulkaninfo'
      ;;
    rocm)
      printf 'Fix:\n  Install AMD'"'"'s ROCm runtime: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/'
      ;;
    openvino)
      printf 'Fix:\n  Install the Intel OpenVINO runtime: https://docs.openvino.ai/latest/openvino_docs_install_guides_overview.html'
      ;;
    sycl-fp16|sycl-fp32)
      printf 'Fix:\n  Install the Intel oneAPI Base Toolkit (DPC++ runtime): https://www.intel.com/content/www/us/en/developer/tools/oneapi/toolkits.html'
      ;;
    *)
      return 1
      ;;
  esac
}

# llama_server_runs: true when the active wrapper can execute --version.
# Kept separate from verify_llama_server so callers that want to fall back
# (e.g. the installer trying the CPU archive) can probe without printing the
# final backend error first.
llama_server_runs() {
  [ -x "$BIN_DIR/llama-server" ] && "$BIN_DIR/llama-server" --version >/dev/null 2>&1
}

# verify_llama_server: shared by the installer and updater. Prints one
# actionable error and returns non-zero when the active backend's binary
# cannot run. Returning (rather than exiting) lets each caller decide whether
# to retry a fallback backend.
verify_llama_server() {
  llama_server_runs && return 0

  local hint
  hint="$(backend_dependency_hint "$LLAMA_CPP_BACKEND" 2>/dev/null)" ||
    hint="Fix:
  Install the missing runtime libraries for your selected backend and rerun."

  cat >&2 <<EOF
Error: installed llama.cpp backend '$LLAMA_CPP_BACKEND' did not run on this system.

$hint

Or, try another backend:
  LLAMA_CPP_BACKEND=cpu $0
  LLAMA_CPP_BACKEND=vulkan $0
EOF
  return 1
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

# llama_cpp_backend_version: prints the installed build number for
# $BIN_DIR/llama.cpp.d/<backend>, or nothing if that slot doesn't exist or
# its binary won't run. Sets LD_LIBRARY_PATH to the backend's own directory
# -- unlike upstream's prebuilt releases (which typically bake in an rpath),
# a locally-built binary such as the CUDA backend needs it to find its
# sibling shared libraries, and running it without would silently look like
# "not installed" rather than an actual version mismatch.
#
# Handles two `llama-server --version` formats upstream has used: older
# builds print "version: 10252 (hash)" (the build number is $2 directly);
# builds since llama.cpp's stable/bleeding-edge split print
# "version: 0.2.0-dev (build 10603, commit hash)" (the semantic version is
# $2 now, with the actual build number in the "(build N, ...)" part
# instead). Reproduces a real bug: taking $2 unconditionally silently
# started returning "0.2.0-dev" for every current build, which never
# equals a resolved b[NUM] tag in llama_cpp_versions_match -- every
# `localai update`/`backend install` call redownloaded and reinstalled an
# already-current backend, every single time.
llama_cpp_backend_version() {
  local backend="$1"
  local dir="$BIN_DIR/llama.cpp.d/$backend"
  LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$dir/llama-server" --version 2>&1 |
    awk '
      /version:/ {
        if (match($0, /\(build [0-9]+/)) {
          print substr($0, RSTART + 7, RLENGTH - 7)
        } else {
          print $2
        }
        exit
      }
    ' || true
}

# llama_cpp_display_tag: prints the installed llama.cpp *build tag* for
# $backend (e.g. b11223) -- the identity the updater compares against and
# that LLAMA_CPP_VERSION pins. This is the short, canonical answer to "which
# version is installed", unlike llama_cpp_display_version's raw
# "version: 0.5.0-dev (build 11223, commit ...)" line, whose leading
# semantic version is upstream's cosmetic label and never matches a release
# tag. Prebuilt backends always self-report a b[NUM] build (a stable
# release's binaries physically live in its nightly b-tag); cuda records the
# exact resolved tag at build time, which may be either family (b[NUM] or
# vX.Y.Z), so it's printed as-is. Prints nothing if the slot has no binary.
llama_cpp_display_tag() {
  local backend="$1" version

  if [ "$backend" = "cuda" ] && command -v cuda_installed_revision >/dev/null 2>&1; then
    version="$(cuda_installed_revision)"
  else
    version="$(llama_cpp_backend_version "$backend")"
  fi
  [ -n "$version" ] || return 0

  case "$version" in
    b*|v*) printf '%s\n' "$version" ;;
    *) printf 'b%s\n' "$version" ;;
  esac
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
# summaries. Filters to the line containing "version:" because llama-server
# also writes initialization log lines to stderr (merged in via 2>&1), which
# would otherwise be picked up as the "first line".
llama_cpp_display_version() {
  local backend="$1" raw
  raw="$("$BIN_DIR/llama-server" --version 2>&1 | awk '/version:/ {print; exit}')"
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
  raw="$(LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" "$dir/llama-server" --version 2>&1 | awk '/version:/ {print; exit}')"
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

_llama_cpp_install_rollback() {
  local staging="${_LLAMA_CPP_INSTALL_STAGING:-}"
  local old="${_LLAMA_CPP_INSTALL_OLD:-}"
  local dest="${_LLAMA_CPP_INSTALL_DEST:-}"

  [ -z "$staging" ] || rm -rf -- "$staging"
  if [ -n "$old" ] && [ -e "$old" ] && [ -n "$dest" ]; then
    rm -rf -- "$dest"
    mv -- "$old" "$dest" 2>/dev/null || true
  fi
  _LLAMA_CPP_INSTALL_STAGING=""
  _LLAMA_CPP_INSTALL_OLD=""
}

_llama_cpp_install_restore_traps() {
  trap - INT TERM
  [ -z "${_LLAMA_CPP_INSTALL_PREV_INT:-}" ] || eval "$_LLAMA_CPP_INSTALL_PREV_INT"
  [ -z "${_LLAMA_CPP_INSTALL_PREV_TERM:-}" ] || eval "$_LLAMA_CPP_INSTALL_PREV_TERM"
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

  # Stage the complete new tree beside the destination, then swap it in with
  # two renames. The long copy/move never touches a working backend, and a
  # failed or interrupted swap restores the previous slot instead of leaving
  # it empty (the old code did `rm -rf` before `mv`).
  _LLAMA_CPP_INSTALL_DEST="$backend_dir"
  _LLAMA_CPP_INSTALL_STAGING="$BIN_DIR/llama.cpp.d/.${LLAMA_CPP_BACKEND}.new.$$"
  _LLAMA_CPP_INSTALL_OLD="$BIN_DIR/llama.cpp.d/.${LLAMA_CPP_BACKEND}.old.$$"
  _LLAMA_CPP_INSTALL_PREV_INT="$(trap -p INT)"
  _LLAMA_CPP_INSTALL_PREV_TERM="$(trap -p TERM)"
  trap '_llama_cpp_install_rollback; exit 130' INT
  trap '_llama_cpp_install_rollback; exit 143' TERM

  rm -rf -- "$_LLAMA_CPP_INSTALL_STAGING" "$_LLAMA_CPP_INSTALL_OLD"
  if ! mv -- "$llama_release_dir" "$_LLAMA_CPP_INSTALL_STAGING"; then
    _llama_cpp_install_rollback
    _llama_cpp_install_restore_traps
    fail "failed to stage llama.cpp backend '$LLAMA_CPP_BACKEND'"
  fi

  if [ -e "$backend_dir" ] && ! mv -- "$backend_dir" "$_LLAMA_CPP_INSTALL_OLD"; then
    _llama_cpp_install_rollback
    _llama_cpp_install_restore_traps
    fail "failed to replace llama.cpp backend '$LLAMA_CPP_BACKEND'"
  fi

  if ! mv -- "$_LLAMA_CPP_INSTALL_STAGING" "$backend_dir"; then
    _llama_cpp_install_rollback
    _llama_cpp_install_restore_traps
    fail "failed to activate llama.cpp backend '$LLAMA_CPP_BACKEND'"
  fi

  _LLAMA_CPP_INSTALL_STAGING=""
  rm -rf -- "$_LLAMA_CPP_INSTALL_OLD"
  _LLAMA_CPP_INSTALL_OLD=""
  _LLAMA_CPP_INSTALL_DEST=""
  _llama_cpp_install_restore_traps

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

# config_rhs_is_self_default: true when KEY's right-hand side is the shipped
# self-referencing default template, e.g. KEY="${KEY:-default}". Those lines
# only express a default, not a user choice, so copying them forward would
# freeze an old release's default forever. Explicit assignments (including
# ones edited to a literal value, with or without an inline comment) are what
# need preserving.
config_rhs_is_self_default() {
  local key="$1"
  local rhs="$2"

  [[ "$rhs" =~ ^[[:space:]]*[\"\']?\$\{${key}:-.*\}[\"\']?([[:space:]]*#.*)?[[:space:]]*$ ]]
}

# config_all_keys: prints every variable assigned by FILE, once each.
config_all_keys() {
  local file="$1"
  local line key
  local -A seen=()

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      key="${BASH_REMATCH[1]}"
      [ -n "${seen[$key]:-}" ] && continue
      seen["$key"]=1
      printf '%s\n' "$key"
    fi
  done < "$file"
}

# config_explicit_keys: prints, once each in file order, every variable the
# previous config assigned explicitly rather than through the shipped
# KEY="${KEY:-...}" default template.
config_explicit_keys() {
  local file="$1"
  local line key rhs
  local -A seen=()

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      rhs="${BASH_REMATCH[2]}"
      config_rhs_is_self_default "$key" "$rhs" && continue
      [ -n "${seen[$key]:-}" ] && continue
      seen["$key"]=1
      printf '%s\n' "$key"
    fi
  done < "$file"
}

# config_eval_keys: sources FILE in a subshell with the requested keys unset
# first, then prints each as KEY=<shell-quoted value>. Sourcing (rather than
# textually slicing) is what makes inline comments, quotes, and expansions
# behave exactly like they do at runtime. Values are emitted with printf %q so
# they can be written back into localai.conf safely no matter what they contain.
config_eval_keys() {
  local file="$1"
  local keys="$2"
  local key

  (
    set +u
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      unset "$key" 2>/dev/null || true
    done <<<"$keys"

    # shellcheck source=/dev/null
    # shellcheck disable=SC1090
    if ! . "$file" >/dev/null 2>&1; then
      exit 1
    fi

    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if [ "${!key+x}" = x ]; then
        printf '%s=%q\n' "$key" "${!key}"
      fi
    done <<<"$keys"
  )
}

# append_runtime_tuning: carries settings the user explicitly changed in the
# previous localai.conf into the freshly installed one. It does not copy the
# shipped KEY="${KEY:-...}" template lines, so future default changes still
# reach upgraded installs.
append_runtime_tuning() {
  local installed_conf="$CONF_DIR/localai.conf"
  local source_conf="$1"
  local marker="$2"
  local all_keys keys values line key value
  local -a preserved=()
  local -A old_values=()

  [ -f "$source_conf" ] || return 0
  all_keys="$(config_all_keys "$source_conf")"
  keys="$(config_explicit_keys "$source_conf")"
  [ -n "$keys" ] || return 0

  values="$(config_eval_keys "$source_conf" "$all_keys")" || {
    echo "Warning: could not read previous settings from $source_conf; they were not preserved." >&2
    return 0
  }

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    value="${line#*=}"
    old_values["$key"]="$value"
  done <<<"$values"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ -n "${old_values[$key]+x}" ] || continue
    preserved+=("$key=${old_values[$key]}")
  done <<<"$keys"

  [ "${#preserved[@]}" -gt 0 ] || return 0

  # Prepend (rather than append) so defaults that reference a preserved value
  # -- e.g. LLAMA_CPP_RELEASE_API using LLAMA_CPP_VERSION -- see the user's
  # value on the same source pass instead of the release default.
  local tmp_conf mode
  tmp_conf="$(mktemp "${installed_conf}.XXXXXX")" || return 1
  mode="$(stat -c '%a' "$installed_conf" 2>/dev/null || printf '644')"
  if ! {
    printf '# Settings preserved by %s.\n' "$marker"
    printf '%s\n' "${preserved[@]}"
    echo
    cat "$installed_conf"
  } > "$tmp_conf"; then
    rm -f -- "$tmp_conf"
    return 1
  fi
  chmod "$mode" "$tmp_conf" 2>/dev/null || true
  mv -f -- "$tmp_conf" "$installed_conf" || {
    rm -f -- "$tmp_conf"
    return 1
  }
}

write_systemd_user_service() {
  local service_file="$1"
  local bin_dir="$2"
  local pid_file="${3:-}"

  cat > "$service_file" <<EOF
[Unit]
Description=LocalAI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=$bin_dir/start.sh
ExecStop=$bin_dir/stop.sh
EOF
  if [ -n "$pid_file" ]; then
    printf 'PIDFile=%s\n' "$pid_file" >> "$service_file"
  fi
  cat >> "$service_file" <<EOF
Restart=on-failure
RestartSec=5
TimeoutStopSec=120

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
  # Remove the retired custom workspace, preserving other user files.
  rm -f -- "$dest_dir/ui.html" "$CONF_DIR/ui/index.html"
  rmdir -- "$CONF_DIR/ui" 2>/dev/null || true
}

# ensure_cli_on_path: makes sure $LOCALAI_USER_BIN_DIR (where the localai CLI
# symlink lives) is actually on PATH for new shells, appending the standard
# PATH block to the caller's shell rc file if it isn't already there.
# ~/.profile only loads for *login* shells -- most terminal emulators open
# non-login interactive shells that source ~/.bashrc/~/.zshrc instead, so
# that's what needs the addition for `localai` to resolve in a newly opened
# terminal. Falls back to ~/.profile for anything else, on the chance it's a
# login-shell-only setup (e.g. a bare TTY or SSH). Idempotent: skips the
# append if the rc file already references the directory.
#
# Return status tells the caller whether re-execing into a fresh shell
# (reconnect_shell_on_path below) is worth attempting: 0 means PATH is
# already correct in the *current* shell, nothing to do; 2 means the rc file
# is now correct but this shell hasn't picked it up, a re-exec would help;
# 1 means the rc file couldn't be fixed at all, a re-exec would not help.
ensure_cli_on_path() {
  case ":$PATH:" in
    *":$LOCALAI_USER_BIN_DIR:"*) return 0 ;;
  esac

  local rc_file
  case "${SHELL:-}" in
    */zsh) rc_file="$HOME/.zshrc" ;;
    */bash) rc_file="$HOME/.bashrc" ;;
    *) rc_file="$HOME/.profile" ;;
  esac

  if grep -qF "$LOCALAI_USER_BIN_DIR" "$rc_file" 2>/dev/null; then
    echo "IMPORTANT: the 'localai' command will not work in THIS terminal window yet."
    echo "$rc_file already references $LOCALAI_USER_BIN_DIR, but this window started before that took effect."
    echo "Run this now:  source $rc_file"
    echo "(or just open a new terminal window)"
    echo
    return 2
  fi

  if [ -w "$rc_file" ] || { [ ! -e "$rc_file" ] && [ -w "$(dirname "$rc_file")" ]; }; then
    {
      echo
      echo "# Added by the LocalAI installer: run \`localai\` from anywhere"
      echo "if [ -d \"$LOCALAI_USER_BIN_DIR\" ] ; then"
      echo "    PATH=\"$LOCALAI_USER_BIN_DIR:\$PATH\""
      echo "fi"
    } >> "$rc_file"
    echo "IMPORTANT: the 'localai' command will not work in THIS terminal window yet."
    echo "Added $LOCALAI_USER_BIN_DIR to PATH in $rc_file, but only new terminal windows pick that up."
    echo "Run this now:  source $rc_file"
    echo "(or just open a new terminal window)"
    echo
    return 2
  fi

  echo "Note: $LOCALAI_USER_BIN_DIR is not in your PATH, and $rc_file isn't writable."
  echo "Add it to your shell profile manually to run localai from anywhere."
  echo
  return 1
}

# reconnect_shell_on_path: when ensure_cli_on_path reports the rc file is
# fixed but this shell isn't (status 2), and we're actually in an
# interactive terminal (stdout is a tty -- true for `curl ... | bash` even
# though stdin is the pipe curl fed the script through), replace this
# process with a fresh interactive shell reading from the real terminal
# device so `localai` works immediately with no action from the user.
# /dev/tty always refers to the controlling terminal regardless of what
# stdin was redirected to, which is what makes this safe to attempt even
# though the script's own stdin is the exhausted curl pipe. A plain
# `exec "$SHELL"` would inherit that same exhausted stdin and misbehave, so
# stdin is explicitly reopened from /dev/tty; stdout/stderr are already the
# terminal (that's what [ -t 1 ] just confirmed) and are left alone. Falls
# through silently if any precondition isn't met -- the message
# ensure_cli_on_path already printed is the fallback.
reconnect_shell_on_path() {
  local ensure_status="$1"

  [ "$ensure_status" -eq 2 ] || return 0
  [ -t 1 ] || return 0
  [ -r /dev/tty ] || return 0
  [ -n "${SHELL:-}" ] && command -v "$SHELL" >/dev/null 2>&1 || return 0

  echo "Switching this terminal to a fresh shell so 'localai' works right now..."
  echo
  exec "$SHELL" -i < /dev/tty
}
