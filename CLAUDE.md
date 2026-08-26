# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native desktop player (macOS + Linux + Windows) for the SUB/WAVE internet radio station, built on the **Vercel Native SDK**: declarative `.native` markup + Zig logic, rendered by the SDK's own engine — no browser, no WebView. Requires **Zig 0.16.0** and a global `@native-sdk/cli` **0.10.1** (`npm i -g @native-sdk/cli`).

## Commands

```bash
native build -Dtrace=off && ./zig-out/bin/subwave-desktop   # release build + run
native dev                                       # debug build, Zig hot-rebuild
native test                                      # all tests: unit tests + markup build/layout contract
native check                                     # validate markup + manifest (app.zon)
native package --target macos --output dist      # distributable (also: --target linux)
```

`-Dtrace=off` belongs on every `native build`: the SDK's default trace mode
does unbounded per-frame file I/O on the message loop thread, which is what
stalled it on Windows behind an AV minifilter (issue #23). See
`docs/sdk-notes.md` and `scripts/check-release-flags.sh`.

Headless verification (no human at the screen):

```bash
native build -Dautomation=true -Dtrace=off
./zig-out/bin/subwave-desktop &
native automate wait && native automate screenshot main-canvas
# screenshot lands in .zig-cache/native-sdk-automation/screenshot-main-canvas.png
```

Point the app at a dev station with `SUBWAVE_STATION_URL=http://localhost:<port>` (overrides the persisted station).

## CRITICAL: local SDK patch

The globally installed `@native-sdk/cli` carries **one required local patch** (`patches/native-sdk-local.patch`, documented in `docs/sdk-notes.md`):

- **Fractional HiDPI scale** in `gtk_host.c` — without it the host reports the integer `gtk_widget_get_scale_factor()` instead of the true `gdk_surface_get_scale()`, so on a fractional-scale Linux desktop (e.g. 167%) the canvas is rasterized oversized and nearest-neighbour-resampled down, which shreds glyph antialiasing and makes all text look pixelated. Linux-only; macOS/Windows already read fractional densities.

**After every `npm i -g @native-sdk/cli` upgrade, run `./scripts/apply-sdk-patches.sh` then `native test`.** The script is idempotent and detects partial application.

SDK 0.6.0 absorbed the other two patches (comptime quota; close-hides-window + reserved tray ids 100/101) — do not re-add them. Their replacements are `app.zon`'s `close_policy` plus `fx.showWindow` / `fx.quitApp`; see `docs/sdk-notes.md`.

**`close_policy` is per-build-target, and `app.zon` cannot scope per platform.** The manifest declares `"quit"` (the only thing Linux compiles — the GTK host has no tray to bring a hidden window back), and `scripts/set-close-policy.sh hide` flips it on the macOS and Windows legs of CI and both release workflows. If you touch that line in `app.zon`, keep the `.close_policy = "…"` shape — the script asserts on it and fails the build rather than silently shipping the wrong close behavior.

## Architecture

Elm-style app: a single `Model`, a `Msg` union, and an `update` reducer. All side effects (HTTP, timers, audio, file writes) flow through the SDK **effects channel** — `update` receives `fx: *Effects` and schedules work; results come back as typed `Msg`s. No view code touches I/O.

- `src/main.zig` — thin entry point: shell/window config, `App.create` wiring (`update_fx`, `init_fx`, `tokens_fn`, `view`, `windows_fn`, …), app-level keyboard fallback (`onKey`), tray menu (`statusItem` / `onCommand`), model-declared mini-player window (`windowsFn`), and slider→model sync. Settings load synchronously here *before* the window opens so a saved station skips onboarding.
- `src/model.zig` — the heart (~2300 lines): `Model`, `Msg`, `boot` (init effects), `update` (the reducer, wires every effect), effect keys, settings JSON apply/save. All strings the model keeps are **copied into fixed `*_store` buffers on the Model** — row structs hold slices into those buffers. No heap ownership in the model.
- `src/views.zig` — view registry + composition, and nothing else. The main window dispatches on `model.phase` (onboarding → player); the player is **composed** from six markup fragments (`views/player-top/-sidebar/-stage/-panel/-deck/-sheets.native`), and this file only decides which conditional ones appear. The LIVE stage was hand-built Zig until SDK 0.6.0 added markup's `<image>` leaf (it needs a square runtime image for cover art); there is no Zig view code left. The mini player (`views/mini.native`) is a model-declared secondary window.
- `src/views/*.native` — markup fragments compiled at comptime via `CompiledMarkupView`; a Model field drift is a compile error.
- Pure support modules, each with inline tests: `api.zig` (endpoint URL builders — the one authority on the station API shape), `json.zig` (std.json typed decoders, `ignore_unknown_fields`; parsed strings are arena-owned so callers copy), `color.zig` (hex/rgb/oklch/color-mix(in oklab) → canvas.Color, real OKLab math), `spectrum.zig` (32-band analyzer ballistics: instant attack, linear decay), `stream_format.zig` (format ↔ Icecast mount table + platform decode gate), `theme.zig` (7 station tokens → `DesignTokens` overrides; only color slots are written so app material survives), `settings.zig` (settings.json in the OS per-app config dir), `update.zig` (compiled-in version + GitHub release-check endpoints + strict semver compare; make-release.sh asserts its version matches app.zon), `links.zig` (every outbound URL the app can open + the per-OS browser argv — comptime-baked, so nothing the network says reaches a command line).
- `app.zon` — manifest (id, platforms, permissions, main window + GPU surface).
- `src/tests.zig` — builds and lays out **every** view fragment against the Model across all tab/sheet/phase branches; pulled in via `main.zig`'s `test` block along with the pure modules' unit tests. Run with `native test`.

Data flow at runtime: timers poll `/api/now-playing`, `/api/state`, `/api/themes`, `/api/session`, `/api/schedule` every few seconds → decoded by `json.zig` → copied into the Model → views rebuild. `fx.playAudio` streams `/stream.mp3`; the audio event channel delivers 32 FFT bands (~25 Hz) which double as the animation clock. Theme changes repaint live through `tokens_fn` without touching layout.

## Gotchas

- **A `/` in a scene window title crashes GTK at app_start on Linux.** Keep the branded "SUB/WAVE" slash out of `app.zon` / `shell_windows` titles; it's fine in `runWithOptions.window_title`.
- **The SDK cannot resize a live window.** Per-mode window shapes apply at next launch only.
- **A `hidden_inset_tall` masthead must pad `insets.left` AND `insets.right`.** The window-control cluster sits on a different edge per platform — macOS traffic lights lead, Windows min/max/close trail — so `onChrome` maps both into `chrome_leading` / `chrome_trailing` and `player-top.native` spacers both ends. Dropping the trailing one put the gear button under the DWM caption buttons on Windows, and fed the host's per-present caption-colour sampler (which reads the pixel 8px leading of the cluster and pushes it through `DWMWA_CAPTION_COLOR` + `USE_IMMERSIVE_DARK_MODE`) an antialiased glyph edge instead of flat header — the caption buttons flickered.
- **The FFT spectrum feed only emits while a window is visibly on screen** (occlusion gate in the SDK). A flat visualizer from an app launched in the background is not a bug — activate the app first.
- SDK 0.10.1 still has **no OS media-controls surface** (no MPNowPlayingInfoCenter / MPRemoteCommandCenter / MPRIS / hardware media keys — re-checked at the 0.10.1 upgrade). The substitutes are the tray extra, the in-window keyboard transport, and the background track toast: 0.8.4 added `fx.showNotification`, so a track change while the app is backgrounded posts a desktop notification. It is opt-in (back panel → NOTIFICATIONS); the *whether* lives in `Model.shouldNotifyTrack` and the *what* in `Model.trackNotification` — both pure, because the effect is inert and unrecorded under fake execution, so no test can observe the call itself. 0.9.1's `id` / `action_label` / `action_command` are all in use: every toast reuses the `now-playing` id so a new track replaces the previous one, and its **Open Player** button comes back as an ordinary application command, which is why `open-player` must stay in sync between `Model.open_player_command` and `onCommand` in `src/main.zig` (a main.zig test spans that route).
- SDK 0.10.1 also has **no audio output-device API** — the platform seam is load/play/pause/stop/seek/volume, with no enumeration and no device property, so there is no in-app "play through these speakers" picker to build. Route it at the OS (`pavucontrol`/PipeWire, Windows volume mixer; macOS has nothing native). The upstream request lives in `docs/sdk-audio-device-request.md`.
- **Cover art loads through `fx.loadImage`, not `fx.fetch` + `registerImageBytes`** — the fetch and the platform decode run on a worker thread, with a content-addressed disk cache under the OS caches dir. Its ImageId **is** the effect key, which is why the counter starts at `keys.cover_image_base` (1000) clear of every other effect key. An id only reaches `model.cover_id` once the runtime reports `.loaded`; anything else leaves the initials disc standing.
- Stream format is listener-selectable (`stream_format.zig`): MP3 is the always-available floor, AAC additionally decodes on macOS (AVPlayer) and Windows (Media Foundation), and the Ogg-encapsulated Opus/FLAC mounts are Linux-only (neither AVPlayer nor Media Foundation has an Ogg demuxer). Every host asserts its **full** matrix in the `platformSupports` test — Windows fell through the defensive `else` for two releases and shipped MP3-only because cross-compiling never ran the suite for the target. Linux offers Ogg mounts optimistically and `scheduleReconnect` drops a failing non-MP3 pick back to MP3 after 3 retries. The picker **lists** every platform-decodable mount and lets you tune only the ones the station advertises via the `stream` flags on `/api/now-playing` — unserved mounts say so on their detail line and their press is absorbed in `update`, so a dead value never reaches `format_pref`. Its entry point is the pressable format chip in the transport deck's SIGNAL row (plus the always-present back-panel row).
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
