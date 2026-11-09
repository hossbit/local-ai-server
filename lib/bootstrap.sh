#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared entry-point bootstrap. Every LocalAI script used to carry its own
# copy of this config-loader preamble; keeping it here means a change to the
# installed/repo lookup rules only has to happen once.
#
# The caller must set SCRIPT_DIR before sourcing this file.

if [ -f "$SCRIPT_DIR/../conf/localai.conf" ]; then
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
