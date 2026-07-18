# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native desktop player (macOS + Linux) for the SUB/WAVE internet radio station, built on the **Vercel Native SDK**: declarative `.native` markup + Zig logic, rendered by the SDK's own engine — no browser, no WebView. Requires **Zig 0.16.0** and a global `@native-sdk/cli` (`npm i -g @native-sdk/cli`).

## Commands

```bash
native build && ./zig-out/bin/subwave-desktop   # release build + run
native dev                                       # debug build, Zig hot-rebuild
native test                                      # all tests: unit tests + markup build/layout contract
native check                                     # validate markup + manifest (app.zon)
native package --target macos --output dist      # distributable (also: --target linux)
```

Headless verification (no human at the screen):

```bash
native build -Dautomation=true
./zig-out/bin/subwave-desktop &
native automate wait && native automate screenshot main-canvas
# screenshot lands in .zig-cache/native-sdk-automation/screenshot-main-canvas.png
```

Point the app at a dev station with `SUBWAVE_STATION_URL=http://localhost:<port>` (overrides the persisted station).

## CRITICAL: local SDK patches

The globally installed `@native-sdk/cli` carries **required local patches** (`patches/native-sdk-local.patch`, documented in `docs/sdk-notes.md`):

1. **canonicalizeComptime quota fix** in `ui_markup.zig` — without it, `native build` fails with `error: evaluation exceeded 1000 backwards branches` at ui_markup.zig ~line 1014. The markup documents in this app are too large for the SDK's default comptime quota.
2. **Close-hides-window behavior** in `appkit_host.m` — without it the red close button quits the app instead of hiding to the menu-bar extra. Also reserves tray item ids 100 (unhide) / 101 (quit), which `main.zig`'s `statusItem` depends on.

**After every `npm i -g @native-sdk/cli` upgrade, run `./scripts/apply-sdk-patches.sh` then `native test`.** The script is idempotent and detects partial application.

## Architecture

Elm-style app: a single `Model`, a `Msg` union, and an `update` reducer. All side effects (HTTP, timers, audio, file writes) flow through the SDK **effects channel** — `update` receives `fx: *Effects` and schedules work; results come back as typed `Msg`s. No view code touches I/O.

- `src/main.zig` — thin entry point: shell/window config, `App.create` wiring (`update_fx`, `init_fx`, `tokens_fn`, `view`, `windows_fn`, …), app-level keyboard fallback (`onKey`), tray menu (`statusItem` / `onCommand`), model-declared mini-player window (`windowsFn`), and slider→model sync. Settings load synchronously here *before* the window opens so a saved station skips onboarding.
- `src/model.zig` — the heart (~2300 lines): `Model`, `Msg`, `boot` (init effects), `update` (the reducer, wires every effect), effect keys, settings JSON apply/save. All strings the model keeps are **copied into fixed `*_store` buffers on the Model** — row structs hold slices into those buffers. No heap ownership in the model.
- `src/views.zig` — view registry + composition. The main window dispatches on `model.phase` (onboarding → player). The player is **composed**: five markup fragments (`views/player-top/-sidebar/-panel/-deck/-sheets.native`) around a Zig-built LIVE stage (`stageView`) — the stage is Zig because it needs `ui.image` for square cover art, which markup deliberately excludes. The mini player (`views/mini.native`) is a model-declared secondary window.
- `src/views/*.native` — markup fragments compiled at comptime via `CompiledMarkupView`; a Model field drift is a compile error.
- Pure support modules, each with inline tests: `api.zig` (endpoint URL builders — the one authority on the station API shape), `json.zig` (std.json typed decoders, `ignore_unknown_fields`; parsed strings are arena-owned so callers copy), `color.zig` (hex/rgb/oklch/color-mix(in oklab) → canvas.Color, real OKLab math), `spectrum.zig` (32-band analyzer ballistics: instant attack, linear decay), `stream_format.zig` (format ↔ Icecast mount table + platform decode gate), `theme.zig` (7 station tokens → `DesignTokens` overrides; only color slots are written so app material survives), `settings.zig` (settings.json in the OS per-app config dir).
- `app.zon` — manifest (id, platforms, permissions, main window + GPU surface).
- `src/tests.zig` — builds and lays out **every** view fragment against the Model across all tab/sheet/phase branches; pulled in via `main.zig`'s `test` block along with the pure modules' unit tests. Run with `native test`.

Data flow at runtime: timers poll `/api/now-playing`, `/api/state`, `/api/themes`, `/api/session`, `/api/schedule` every few seconds → decoded by `json.zig` → copied into the Model → views rebuild. `fx.playAudio` streams `/stream.mp3`; the audio event channel delivers 32 FFT bands (~25 Hz) which double as the animation clock. Theme changes repaint live through `tokens_fn` without touching layout.

## Gotchas

- **A `/` in a scene window title crashes GTK at app_start on Linux.** Keep the branded "SUB/WAVE" slash out of `app.zon` / `shell_windows` titles; it's fine in `runWithOptions.window_title`.
- **The SDK cannot resize a live window.** Per-mode window shapes apply at next launch only.
- **The FFT spectrum feed only emits while a window is visibly on screen** (occlusion gate in the SDK). A flat visualizer from an app launched in the background is not a bug — activate the app first.
- SDK 0.5.x has **no OS media-controls surface** (no MPNowPlayingInfoCenter / MPRemoteCommandCenter / MPRIS / hardware media keys). The tray extra + in-window keyboard transport are the substitutes.
- Stream format is listener-selectable (`stream_format.zig`): MP3 is the always-available floor, AAC additionally decodes on macOS, and the Ogg-encapsulated Opus/FLAC mounts are Linux-only (AVPlayer has no Ogg demuxer). Linux offers Ogg mounts optimistically and `scheduleReconnect` drops a failing non-MP3 pick back to MP3 after 3 retries; the picker only shows mounts the station advertises via the `stream` flags on `/api/now-playing`.
- `native automate assert` regex does **not** support `|` alternation.

## Design constraints (for any UI work)

The design envelope is documented in `design-reference/claude-design-brief.md`; stay inside it:

- **Color:** only the 7 station theme tokens (`bg`, `ink`, `muted`, `accent`, `field`, `soft-border`, `overlay`). No per-element hex, no gradients, no alpha layering.
- **Typography:** one sans face + a mono channel, fixed scale (sm ~12 / body ~14 / heading 28 / display 48). No letter-spacing, no text-transform (author uppercase as uppercase text).
- No shadows, blur, absolute positioning, or free-form drawing — the widget vocabulary is closed.
- The built-in icon set is a closed compile-checked list; app-specific icons are registered SVGs in `src/icons/` reached from markup as `icon="app:<name>"`.

## Docs

- `docs/sdk-notes.md` — the local SDK patches in detail (read before any SDK upgrade).
- `docs/2026-07-12-native-desktop-player-plan.md` — original plan and locked decisions.
- `README.md` — features, layout map, codec/format-picker matrix, and shipping checklist.
