# Tracked upstream versions

Weekly record of the llama.cpp / llama-swap versions actually resolved by this
project. localai.conf pins both to `latest`; this file documents what that
resolved to each week. Updated by the weekly update cycle (Sunday).

| Week (Sun -> Sun) | Change | llama.cpp | llama-swap | Backend | Updated |
|---|---|---|---|---|---|
| 2026-08-30 -> 2026-09-06 | Upstream tracking only: llama.cpp v0.2.0 -> v0.4.0 (commit 427291b, released 2026-09-04); llama-swap v251 -> v255 (commit 7761aa1, released 2026-09-06). Pure tracking — no localai source changes, so no release. The project clone was missing on this host since ~2026-08-27 (weekly runs on 08-30 and 09-06 were blocked); re-created 2026-09-06, which is why this row covers the week the 2026-08-30 run could not document. | v0.4.0 (427291b) | v255 (7761aa1) | cuda | 2026-09-06 |
| 2026-08-23 -> 2026-08-30 | llama.cpp started publishing stable `vX.Y.Z` releases alongside the existing `b[NUM]` bleeding-edge builds (v0.2.0 published 2026-08-21; see https://github.com/ggml-org/ggml/discussions/1579). Because `vX.Y.Z` releases are non-prerelease, GitHub's `/releases/latest` now resolves to them instead of the newest `b[NUM]` build, and they ship no binaries of their own (only a `nightly-tag.txt` pointer to the corresponding `b[NUM]` release). Added `LLAMA_CPP_CHANNEL` (`bleeding-edge`\|`stable`) plus channel-aware release resolution (`resolve_llama_cpp_latest_json`, `resolve_llama_cpp_binary_json` in lib/install.sh) so `LLAMA_CPP_VERSION=latest` keeps tracking `b[NUM]` by default and can opt into the `vX.Y.Z` channel instead. llama.cpp: b10453 -> b10603; llama-swap: v250 -> v251. | b10603 | v251 | cuda | 2026-08-23 |
| 2026-08-16 -> 2026-08-23 | llama.cpp: b10410 -> b10453 (CUDA source build, commit 3cb7ffb); llama-swap: v249 -> v250 (60226b6) | b10453 (3cb7ffb) | v250 (60226b6) | cuda | 2026-08-16 |
| 2026-08-09 -> 2026-08-16 | (baseline) | b10410 (154d57a) | v249 (f94c94a) | cuda | 2026-08-13 |
