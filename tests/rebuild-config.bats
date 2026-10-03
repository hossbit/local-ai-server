#!/usr/bin/env bats
#
# EXTRA_ARGS (conf/models.d/<model-id>.conf) is spliced into a `cmd:` string
# that llama-swap re-parses with its own shell-like tokenizer. A plain-string
# EXTRA_ARGS relies on llama-swap splitting it on whitespace (legacy
# behavior, kept for backward compatibility); an array-form EXTRA_ARGS lets
# one element carry embedded spaces/quotes (e.g. a --chat-template-kwargs
# JSON blob) by having rebuild-config.sh single-quote each element itself,
# so the value survives that second parse without any manual escaping.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  AI_DIR="$BATS_TEST_TMPDIR/ai"
  mkdir -p "$AI_DIR/conf/models.d" "$AI_DIR/models" "$AI_DIR/bin"

  # Minimal stand-in for llama-server: only needs to exist/be executable so
  # llama_server_supports_ngl_auto's `--help` probe doesn't fail the run.
  cat > "$AI_DIR/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "--n-gpu-layers N ... 'auto' ..."
EOF
  chmod +x "$AI_DIR/bin/llama-server"

  : > "$AI_DIR/models/model-a.gguf"
  : > "$AI_DIR/models/model-b.gguf"

  LOCALAI_DIR="$AI_DIR"
  export LOCALAI_DIR
  # AUTO_TUNE=0 keeps the test independent of real GPU/RAM detection; every
  # other setting falls back to the repo's own localai.conf defaults.
  AUTO_TUNE=0
  export AUTO_TUNE
}

run_rebuild() {
  run bash "$REPO_DIR/rebuild-config.sh" "$AI_DIR/conf/config.yaml"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

# cmd_for_model NAME: prints the (folded-to-one-line) cmd string generated
# for model NAME, so tests can inspect exactly what argv llama-swap would
# tokenize.
cmd_for_model() {
  local name="$1"
  awk -v name="\"$name\":" '
    $0 == "  "name { found=1; next }
    found && /^  "/ { exit }
    found && /^    cmd: >/ { incmd=1; next }
    found && incmd && /^    [a-zA-Z]+:/ { exit }
    found && incmd { sub(/^      /, ""); printf "%s ", $0 }
  ' "$AI_DIR/conf/config.yaml"
}

@test "array-form EXTRA_ARGS survives the generated cmd string as one argv token" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
EXTRA_ARGS=(--chat-template-kwargs '{"enable_thinking":false}')
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"'--chat-template-kwargs'"* ]]
  [[ "$cmd_line" == *"'{\"enable_thinking\":false}'"* ]]

  # Reproduce llama-swap's re-parse: fold the generated string through a
  # shell tokenizer and confirm the flag and its JSON value come back as
  # two distinct, untouched argv elements (this is the exact bug that
  # shipped broken: the JSON's own quotes got stripped by this re-parse).
  local -a argv=()
  eval "argv=($cmd_line)"
  local token flag_found=0 json_found=0
  for token in "${argv[@]}"; do
    [ "$token" = '--chat-template-kwargs' ] && flag_found=1
    [ "$token" = '{"enable_thinking":false}' ] && json_found=1
  done
  [ "$flag_found" -eq 1 ]
  [ "$json_found" -eq 1 ]
}

@test "legacy plain-string EXTRA_ARGS still splices unquoted, unchanged" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
EXTRA_ARGS="--reasoning-budget 0"
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--reasoning-budget 0"* ]]
  # must NOT have been quoted -- that would change legacy behavior
  [[ "$cmd_line" != *"'--reasoning-budget 0'"* ]]
}

@test "EXTRA_ARGS from one model's array override does not leak into the next model" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
EXTRA_ARGS=(--chat-template-kwargs '{"enable_thinking":false}')
EOF
  # model-b has no override file at all.
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-b)"
  [[ "$cmd_line" != *"enable_thinking"* ]]
  [[ "$cmd_line" != *"chat-template-kwargs"* ]]
}

@test "N_CPU_MOE wins over CPU_MOE and OVERRIDE_TENSOR survives regex backslashes" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
CPU_MOE=1
N_CPU_MOE=20
OVERRIDE_TENSOR="blk\.(2[0-9]|[3-9][0-9])\.ffn_.*_exps\.=CPU"
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--n-cpu-moe 20"* ]]
  [[ "$cmd_line" != *"--cpu-moe"* ]]

  local -a argv=()
  eval "argv=($cmd_line)"
  local token found=0
  for token in "${argv[@]}"; do
    [ "$token" = 'blk\.(2[0-9]|[3-9][0-9])\.ffn_.*_exps\.=CPU' ] && found=1
  done
  [ "$found" -eq 1 ]
}

@test "CPU_MOE=1 alone adds --cpu-moe" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
CPU_MOE=1
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--cpu-moe"* ]]
  [[ "$cmd_line" != *"--n-cpu-moe"* ]]
}

@test "reasoning overrides render their flags" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
REASONING=auto
REASONING_BUDGET=-1
REASONING_FORMAT=deepseek
REASONING_PRESERVE=1
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--reasoning auto"* ]]
  [[ "$cmd_line" == *"--reasoning-budget -1"* ]]
  [[ "$cmd_line" == *"--reasoning-format deepseek"* ]]
  [[ "$cmd_line" == *"--reasoning-preserve"* ]]
}

@test "invalid REASONING value fails the rebuild" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
REASONING=sometimes
EOF
  run bash "$REPO_DIR/rebuild-config.sh" "$AI_DIR/conf/config.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REASONING"* ]]
}

@test "SPEC_DRAFT_MODEL and LORA/LORA_SCALED render as separate quoted argv tokens" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
SPEC_DRAFT_MODEL="/path/to/draft model.gguf"
SPEC_DRAFT_N_MIN=2
LORA="/path/to/a.gguf, /path/to/b.gguf"
LORA_SCALED="/path/to/c.gguf:0.5"
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--spec-draft-n-min 2"* ]]

  local -a argv=()
  eval "argv=($cmd_line)"
  local token draft_found=0 lora_joined=0 lora_scaled=0
  for token in "${argv[@]}"; do
    [ "$token" = '/path/to/draft model.gguf' ] && draft_found=1
    [ "$token" = '/path/to/a.gguf,/path/to/b.gguf' ] && lora_joined=1
    [ "$token" = '/path/to/c.gguf:0.5' ] && lora_scaled=1
  done
  [ "$draft_found" -eq 1 ]
  [ "$lora_joined" -eq 1 ]
  [ "$lora_scaled" -eq 1 ]
}

@test "SPEC_DRAFT_CACHE_TYPE_K/V render as draft cache flags inside the draft block" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOT'
SPEC_DRAFT_MODEL="/path/to/draft.gguf"
SPEC_DRAFT_CACHE_TYPE_K=q8_0
SPEC_DRAFT_CACHE_TYPE_V=f16
EOT
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--cache-type-k-draft q8_0"* ]]
  [[ "$cmd_line" == *"--cache-type-v-draft f16"* ]]
}

@test "SPEC_DRAFT_N_CPU_MOE wins over SPEC_DRAFT_CPU_MOE" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOT'
SPEC_DRAFT_MODEL="/path/to/draft.gguf"
SPEC_DRAFT_CPU_MOE=1
SPEC_DRAFT_N_CPU_MOE=12
EOT
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--n-cpu-moe-draft 12"* ]]
  [[ "$cmd_line" != *"--cpu-moe-draft"* ]]
}

@test "SPEC_DRAFT_CPU_MOE=1 alone adds --cpu-moe-draft" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOT'
SPEC_DRAFT_MODEL="/path/to/draft.gguf"
SPEC_DRAFT_CPU_MOE=1
EOT
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--cpu-moe-draft"* ]]
  [[ "$cmd_line" != *"--n-cpu-moe-draft"* ]]
}

@test "new draft knobs do not leak into a model without an override file" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOT'
SPEC_DRAFT_MODEL="/path/to/draft.gguf"
SPEC_DRAFT_CACHE_TYPE_K=q8_0
SPEC_DRAFT_CPU_MOE=1
EOT
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-b)"
  [[ "$cmd_line" != *"--cache-type-k-draft"* ]]
  [[ "$cmd_line" != *"--cpu-moe-draft"* ]]
}

@test "invalid SPEC_DRAFT_CACHE_TYPE_K fails the rebuild" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOT'
SPEC_DRAFT_CACHE_TYPE_K="bad
value"
EOT
  run bash "$REPO_DIR/rebuild-config.sh" "$AI_DIR/conf/config.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPEC_DRAFT_CACHE_TYPE_K"* ]]
}

@test "MMPROJ_URL is skipped when a local MMPROJ is already set, MMPROJ_OFFLOAD requires one of them" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
MMPROJ=/path/to/mmproj.gguf
MMPROJ_URL=https://example.com/mmproj.gguf
MMPROJ_OFFLOAD=1
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-a)"
  [[ "$cmd_line" == *"--mmproj \"/path/to/mmproj.gguf\""* ]]
  [[ "$cmd_line" != *"--mmproj-url"* ]]
  [[ "$cmd_line" == *"--mmproj-offload"* ]]
}

@test "new per-model knobs do not leak into a model without an override file" {
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
N_CPU_MOE=20
REASONING=on
LORA=/path/to/a.gguf
EOF
  run_rebuild

  local cmd_line
  cmd_line="$(cmd_for_model model-b)"
  [[ "$cmd_line" != *"n-cpu-moe"* ]]
  [[ "$cmd_line" != *"--reasoning"* ]]
  [[ "$cmd_line" != *"--lora"* ]]
}

@test "LOCALAI_MTP_MODELS_DIR renders --models-dir with quoting" {
  LOCALAI_MTP_MODELS_DIR="/data/mtp models"
  export LOCALAI_MTP_MODELS_DIR
  run_rebuild
  cmd_for_model model-a | grep -q -- "--models-dir '/data/mtp models'" || {
    echo "cmd: $(cmd_for_model model-a)" >&2
    fail "expected --models-dir in generated cmd"
  }
}

@test "LOCALAI_MTP_MODELS_DIR absent by default (no --models-dir leak)" {
  run_rebuild
  if cmd_for_model model-a | grep -q -- "--models-dir"; then
    echo "cmd: $(cmd_for_model model-a)" >&2
    fail "unexpected --models-dir with knob unset"
  fi
}

@test "probabilistic sampling is emitted only for supported draft modes" {
  cat > "$AI_DIR/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo '--n-gpu-layers auto --spec-draft-sampling'
EOF
  cat > "$AI_DIR/conf/models.d/model-a.conf" <<'EOF'
SPEC_TYPE=draft-mtp
SPEC_DRAFT_SAMPLING=probabilistic
EOF
  run_rebuild
  [[ "$(cmd_for_model model-a)" == *'--spec-draft-sampling probabilistic'* ]]
  [[ "$(cmd_for_model model-b)" != *'--spec-draft-sampling'* ]]
}
@test "unsupported pinned engine rejects requested draft sampling" {
  printf 'SPEC_TYPE=draft-mtp\nSPEC_DRAFT_SAMPLING=greedy\n' > "$AI_DIR/conf/models.d/model-a.conf"
  run bash "$REPO_DIR/rebuild-config.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not support it'* ]]
}
@test "invalid draft sampling is rejected" {
  SPEC_DRAFT_SAMPLING=invalid run bash "$REPO_DIR/rebuild-config.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be greedy or probabilistic'* ]]
}

@test "failed model validation preserves both working configuration files" {
  printf 'working config\n' > "$AI_DIR/conf/config.yaml"
  mkdir -p "$AI_DIR/conf/keys.d"
  printf 'working keys\n' > "$AI_DIR/conf/keys.d/keys.yaml"
  printf 'SPEC_TYPE=draft-mtp\nSPEC_DRAFT_SAMPLING=greedy\n' > "$AI_DIR/conf/models.d/model-a.conf"
  run bash "$REPO_DIR/rebuild-config.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$AI_DIR/conf/config.yaml")" = 'working config' ]
  [ "$(cat "$AI_DIR/conf/keys.d/keys.yaml")" = 'working keys' ]
  [ "$(find "$AI_DIR/conf" -name '*.??????' | wc -l)" -eq 0 ]
}
