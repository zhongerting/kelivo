# Upstream customization merge — 2026-09-09

Merged `origin/codex/chat-instruction-shortcuts` at `99e8ecf0` into the
custom feature branch based on `d2f4a093`. Version becomes `1.2.6+73`.

Resolved four ARB end-of-file conflicts by preserving both sets of keys and
regenerated the three localization Dart files. No feature side was discarded.
Adapted story-memory generation to pass the conversation ID through to the
shared API, matching upstream OpenCode session-header support. A pipeline test
asserts that the original conversation ID reaches the generator.

Validation:

- Strict Dart analysis passed; adaptation files formatted.
- 102 focused tests passed: story memory, reply options, thinking filtering,
  prompt presets, character cards, world books, reasoning slider, auto retry,
  and OpenCode sessions.
- Full Windows suite: 4172 passed, 24 failed, 6 skipped. The pre-merge run was
  4108 passed, 26 failed, 6 skipped. Failures remain in path handling, file
  locking and platform-dependent test environments. This is not an all-green
  suite or proof that every possible behavior is regression-free.
- Logs: `E:\devtools\kelivo-merge-tests-20260909.log` and
  `E:\devtools\kelivo-merge-focused-20260909.log`.
- Release build directory: `E:\devtools\kelivo-merge-build-20260909`.
  Its lib/assets were hash-compared with the tested source.

No connected Android device or available default AVD was found during this
task. Physical-device installation, interactive UI and live-provider testing
remain outside this verification. The local analysis_options.yaml platform
exclusions were preserved but excluded from the merge commit.
