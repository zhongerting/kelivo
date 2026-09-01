# AGENTS.md

## Project overview

Kelivo is a cross-platform LLM chat client built with Flutter, targeting iOS, Android, macOS, Windows, and Linux. Package name is `Kelivo` — imports use `package:Kelivo/...`.

## Fork mission

This repository is the user's personal Kelivo fork. The primary product goal is
an Android-ready chat client with faster access to reusable prompts and better
compatibility with the user's existing SillyTavern data. Keep the application
cross-platform, but treat the Android release build as the main delivery
artifact.

Do not remove the custom behavior listed below while merging upstream changes.
When upstream touches the same area, preserve the intent of the customization
and adapt it to the new architecture instead of blindly accepting either side
of the merge.

## Repository topology and upstream sync

- `origin` is the user's fork: `https://github.com/zhongerting/kelivo.git`.
- `upstream` is the official repository: `https://github.com/Chevey339/kelivo.git`.
- `master` follows the official upstream branch.
- `codex/chat-instruction-shortcuts` is the long-lived customization branch.
- Pushes to `upstream` are intentionally disabled. Only push user work to
  `origin`.
- `.github/workflows/sync-upstream.yml` runs daily at approximately 08:23
  Asia/Shanghai, updates the fork's `master`, merges it into the customization
  branch, runs its focused verification, and pushes the result.
- Automatic sync cannot resolve merge conflicts. If it fails, merge
  `origin/master` into the customization branch locally, preserve the features
  below, run verification, and push the repaired branch.

## Custom work in this fork

The following work is part of the fork's intended product behavior:

- **Chat instruction injection management**: instruction-injection cards can be
  opened and managed from the chat interface, including adding, editing, and
  deleting cards without returning to Settings.
- **Official update notices disabled by default**: new installations of this
  fork do not show official-build update notices. An explicit saved user choice
  still wins.
- **SillyTavern world-book import**: mobile and desktop world-book pages accept
  common SillyTavern lorebook JSON shapes, normalize supported fields, report
  skipped entries or adjusted unsupported settings, and retain native Kelivo
  import support. A minimal fixture lives at
  `samples/sillytavern-minimal-world-book.json`.
- **Android debug coexistence**: debug builds use a distinct application ID and
  label so they can coexist with the installed release build.
- **Custom Android launcher icon**: launcher assets and
  `flutter_launcher_icons.yaml` use the user's supplied icon.
- **Quick-phrase dual action**: tapping a quick-phrase row sends that phrase
  immediately. The `Append` / `追加` button on the right inserts it at the
  current input selection without sending. Direct send must preserve any draft
  text and attachments already in the composer; append must restore focus to
  the input. Mobile and desktop menus return the same explicit action type
  (`QuickPhraseSelection`) and must retain identical semantics.

## Current task and acceptance criteria

The current customization task is to make reusable prompts fast enough for
normal chat use without repeatedly entering Settings. For quick phrases, the
acceptance criteria are:

1. Tapping the phrase title/content area sends only that phrase through the
   normal chat send path.
2. Tapping `Append` / `追加` inserts the phrase at the current caret or replaces
   the current selection, without sending it.
3. The append tap must not bubble into the row's send action.
4. Existing composer text and attachments remain untouched by direct send.
5. Mobile and desktop behavior, localization, and accessibility labels remain
   aligned.

The focused regression test is
`test/features/quick_phrase/widgets/quick_phrase_menu_test.dart`.

## Android release delivery

- Deliver **Release** APKs for real-device use. Flutter Debug APKs caused severe
  keyboard-opening lag on the user's Android device and are not valid
  performance artifacts.
- The repository path contains non-ASCII characters. For reliable Android
  builds on this machine, stage or update the source in the ASCII-only worktree
  `E:\devtools\kelivo-apk-build`.
- Use JDK 17 from `E:\devtools\temurin-17\jdk-17.0.20.1+1` when the local Gradle
  environment does not select a compatible JDK automatically.
- Locally installable Profile/Release builds currently use
  `C:\Users\HC Zhao\.android\debug.keystore` through the ignored
  `android/key.properties` file. Reusing this certificate lets a Release APK
  replace the previously delivered Profile build. This is personal test
  signing only; never commit the key configuration, and replace it with a
  private release key before any public store distribution.
- A normal delivery build is `flutter build apk --release`. Confirm the output
  is under `build/app/outputs/flutter-apk/` and report the exact path and file
  size to the user.

## Known local verification baseline

As of 2026-09-01, the focused quick-phrase test and strict analysis of all files
touched by that feature pass. The full Windows test suite has unrelated
pre-existing failures, primarily assertions that compare `/` and `\\` path
separators. Full strict analysis also reports four existing
`unawaited_return_in_try_block` warnings outside this feature. Do not attribute
those baseline failures to quick phrases, but do report them accurately and do
not add new failures.

## Architecture

- **Feature-based structure**: `lib/features/<feature>/` with `pages/`, `widgets/`, `models/`, `utils/` subdirectories.
- **Desktop / mobile split**: most UI pages have separate desktop and mobile layouts (e.g. `home_desktop_layout.dart` / `home_mobile_layout.dart`). Desktop-only code lives in `lib/desktop/`. Use `ResponsiveHelper` from `lib/shared/responsive/` to branch by screen type.
- **State management**: Provider (`lib/core/providers/`).
- **Database**: Drift (`lib/core/database/`). Schema versions tracked in `drift_schemas/`.
- **Localization**: ARB-based (`lib/l10n/`), English template (`app_en.arb`). Run `flutter gen-l10n` after editing ARB files and commit the generated output.

## Pre-commit checklist

All three must pass before committing:

```bash
dart format lib test                        # format changed files
dart analyze --fatal-infos lib test         # zero warnings, zero infos
flutter test                                # all unit tests green
```

CI (`pr-check.yml`) enforces the same gates on every PR.

## Benchmarks are not tests

`test/perf/*_bench.dart` print timings and contain no `expect()`, so they cannot
fail. They are named out of the default `_test.dart` glob and so are skipped by
`flutter test`. Run one explicitly:

```bash
flutter test test/perf/timeline_scroll_bench.dart
```

## UI guidelines

- **Use app-defined widgets** from `lib/shared/widgets/` and `lib/shared/dialogs/` instead of raw Flutter/Material widgets wherever an equivalent exists (e.g. `SectionCard`, `CustomBottomSheet`, `IosFormTextField`, `IosCheckbox`, `InteractiveDrawer`).
- **BottomSheet**: both Flutter's built-in bottom sheet and `CustomBottomSheet` are fine on mobile. Never use any bottom sheet on desktop — use a dialog or another interaction pattern instead.
- **Icons**: use `lucide_icons_flutter`, not `Icons.*` from Material.
- **Animations**: use `flutter_animate` / `animations` for motion.
- When building a new page, create separate desktop and mobile layouts unless the page is trivially simple. Wire them together via `ResponsiveHelper`.

## Code style

- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Local dependencies

Several packages live under `dependencies/` and are referenced by path in `pubspec.yaml` (e.g. `gpt_markdown`, `mcp_client`, `flutter_tts`, `flutter_math_fork`, `downsize`). The analyzer excludes `dependencies/flutter_math_fork/**` and `dependencies/flutter_tts/**`.

## Useful commands

```bash
flutter pub get                             # install dependencies
flutter gen-l10n                            # regenerate l10n files
dart run build_runner build                 # regenerate Drift code
```
