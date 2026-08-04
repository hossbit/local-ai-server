# shellcheck shell=bash disable=SC2154

# switch_cmd: instant switch when the requested backend was already installed
# before (its own slot under $BIN_DIR/llama.cpp.d/<backend> still has a
# working llama-server), otherwise falls through to the normal install/update
# flow. Deliberately does not duplicate the cpu/vulkan/rocm/openvino/sycl-*/
# cuda name validation that lib/install.sh already does -- an unrecognized
# name just reaches that fallback and gets the same error from there.
switch_cmd() {
  local requested="${1:-}" resolved backend_dir

  if [ -z "$requested" ] || [ "$#" -ne 1 ]; then
    fail "usage: localai switch <backend>  (cpu, vulkan, rocm, openvino, sycl-fp16, sycl-fp32, cuda, auto)"
  fi

  resolved="$requested"
  [ "$requested" = "auto" ] && resolved="$(cuda_resolve_auto_backend)"
  backend_dir="$BIN_DIR/llama.cpp.d/$resolved"

  if [ -x "$backend_dir/llama-server" ] &&
    LD_LIBRARY_PATH="$backend_dir:${LD_LIBRARY_PATH:-}" "$backend_dir/llama-server" --help >/dev/null 2>&1; then
    echo "Switching to already-installed $resolved backend"
    LLAMA_CPP_BACKEND="$resolved" activate_llama_cpp_backend
    service_cmd restart
    return 0
  fi

  echo "$resolved backend not installed yet; installing it now"
  LLAMA_CPP_BACKEND="$requested" update_cmd
}
