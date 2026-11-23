#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared entry-point bootstrap. Every LocalAI script used to carry its own
# copy of this config-loader preamble; keeping it here means a change to the
# installed/repo lookup rules only has to happen once.
#
# The caller must set SCRIPT_DIR before sourcing this file.

if [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
  # localai.conf picks CPU-safe runtime defaults (context, parallel slots,
  # GPU layers, ...) when LLAMA_CPP_BACKEND is cpu. Installed scripts are not
  # told the backend, so without this every CPU install silently ran with the
  # GPU profile. An explicitly requested backend (switch, backend install,
  # environment) still wins.
  if [ -z "${LLAMA_CPP_BACKEND:-}" ] &&
    [ -f "$SCRIPT_DIR/../conf/${LOCALAI_BACKEND_FILE:-llama-cpp-backend}" ]; then
    _localai_installed_backend="$(head -n1 "$SCRIPT_DIR/../conf/${LOCALAI_BACKEND_FILE:-llama-cpp-backend}" 2>/dev/null || true)"
    case "$_localai_installed_backend" in
      cpu|vulkan|rocm|openvino|sycl-fp16|sycl-fp32|cuda) LLAMA_CPP_BACKEND="$_localai_installed_backend" ;;
    esac
    unset _localai_installed_backend
  fi
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/../conf/localai.conf"
elif [ -f "$SCRIPT_DIR/localai.conf" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/localai.conf"
else
  echo "Error: localai.conf not found." >&2
  exit 1
fi

_source_localai_common() {
  local candidate

  for candidate in "$SCRIPT_DIR/lib/common.sh" "$SCRIPT_DIR/../lib/common.sh"; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done

  echo "Error: missing LocalAI library: common.sh" >&2
  exit 1
}

_source_localai_common
unset -f _source_localai_common
