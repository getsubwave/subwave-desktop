# subwave-desktop

A native desktop player for the [SUB/WAVE](https://www.getsubwave.com) internet
radio station, built on the **Vercel Native SDK** — declarative `.native` markup
+ Zig logic, drawn by the SDK's own engine (no browser, no WebView). Separate
repo from the main `subwave` monorepo; it tracks the same station HTTP API.

## Features

- **Live stream** — plays the endless Icecast MP3 (`/stream.mp3`) via
  `fx.playAudio`, with play/pause/tune-out, volume, and 500 ms→60 s reconnect
  backoff.
- **Now playing** — 5 s poll of `/api/now-playing` + `/api/state`: title, artist,
  album, genre, DJ, active show, listener count, elapsed.
- **Cover art** — fetches `/api/cover/:id`, decodes and registers it as a disc.
- **Real spectrum** — the SDK's FFT `.spectrum` feed (32 bands) rendered as an
  accent-themed bar analyzer with classic attack/decay ballistics.
- **Station themes** — polls `/api/themes` and repaints live via `DesignTokens`;
  the resolver (`color.zig`) converts hex / rgb() / **oklch()** /
  **color-mix(in oklab, …)** to real colors.
- **Two skins** — **Card** (roomy now-playing) and **Deck** (compact hi-fi
  strip), switchable at runtime; both honor the station theme.
- **Song requests** — a text field posts to `/api/request` and polls the result.
- **Booth ticker** — the DJ's latest on-air line from `/api/session`.
- **Station guide** — `/api/schedule` show list with topics, personas, and a
  live-show dot, toggled from the header.
- **Settings persistence** — volume/skin/theme-override/station survive
  restarts (`settings.json` in the OS per-app config dir); the window shape
  follows the saved skin at launch (Card 620×460, Deck 540×300).
- **Menu-bar extra** — a status item (macOS `NSStatusItem`) with the live
  now-playing lines and Play/Pause + Tune out, so the player is controllable
  while the window is buried.
- **Keyboard transport** — space = play/pause, ↑/↓ = volume (app-level
  fallback; never steals typing from the request/station fields).

## Layout

```
app.zon                 manifest (id, platforms {macos,linux}, window)
src/
  main.zig              App wiring (create + runWithOptions), view = skins.rootView
  model.zig             Model / Msg / update (the reducer heart) + effects
  api.zig               endpoint URL builders (pure)
  json.zig              std.json typed decoders for each payload
  color.zig             hex/rgb/oklch/color-mix → canvas.Color (OKLab math) + tests
  theme.zig             7 station tokens → DesignTokens; tokens_fn (skin-aware)
  spectrum.zig          band ballistics (pure) + tests
  skins.zig             AppSkin registry; rootView branches on model.skin
  skins/card.native     Card layout
  skins/deck.native     Deck layout
  tests.zig             view build/layout + pulls color/spectrum unit tests
```

The player runs entirely through the SDK **effects channel** (`.update_fx`):
timers drive polling, `fx.fetch` does HTTP, results return as typed Msgs, and
`fx.playAudio`/`registerImageBytes` handle audio + cover art.

## Build & run

Requires **Zig 0.16.0** and the `@native-sdk/cli` (`npm i -g @native-sdk/cli`).

```bash
native build && ./zig-out/bin/subwave-desktop   # release build + run
native dev                                       # debug build, Zig hot-rebuild
native test                                      # unit tests + typed markup contract
native check                                     # validate markup + manifest
native package --target linux --output dist      # distributable (also: --target macos)
```

Headless verification (CI / agents) via the built-in automation server:

```bash
native build -Dautomation=true
./zig-out/bin/subwave-desktop &
native automate wait && native automate screenshot main-canvas
```

## Codecs & platform integration (current status)

**Stream codec: MP3 only, by design.** The player tunes the station's
`/stream.mp3` mount; Opus/FLAC/AAC mounts are out of scope for v1 (see
`docs/…plan.md`). If that changes, backend support is:

| Codec over Icecast | macOS (AVPlayer) | Linux (GStreamer `playbin`) |
|---|---|---|
| MP3 | ✅ | ✅ |
| AAC (ADTS) | ✅ | ✅ where `gst-plugins-bad`/`libav` present |
| Ogg Opus | ❌ not supported by AVFoundation | ✅ (`gst-plugins-base`) |
| FLAC | ❌ no endless-stream FLAC | ✅ (`gst-plugins-good`) |

**OS media integration.** The SDK (0.5.1) has no system now-playing or
media-key surface — no `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` on
macOS, no MPRIS on Linux — so hardware play/pause keys and the OS Now Playing
widget can't be wired up yet (SDK feature request). What IS wired up: the
menu-bar status item (tray on Linux where supported), the in-window keyboard
transport, and per-track fetch of the station's own metadata (the app polls
`/api/now-playing` rather than relying on ICY in-stream metadata).

## Notes & gotchas

- **Audio playback works on Linux** (GTK + GStreamer) in this SDK build, despite
  the docs marking GTK/Win32 audio as unsupported. macOS uses AVFoundation
  (one `AVPlayer` + `MTAudioProcessingTap` for the spectrum feed).
- `model.zig` `boot_volume` defaults to **0.8**; the persisted volume from
  `settings.json` wins after first run. Decode/position/spectrum report even
  at volume 0.
- **Gotcha:** a `/` in the *scene* window title crashes GTK at `app_start`; keep
  the branded slash out of `app.zon`/`shell_windows` titles (it's fine in
  `runWithOptions.window_title`).
- The SDK can't resize a live window: a runtime skin switch relays out in the
  old shape; the per-skin window shape applies at next launch.

## Shipping checklist

- `native package --target macos --output dist` builds the `.app`;
  sign + notarize with a Developer ID identity (the CLI wraps
  `codesign`/`notarytool`). Linux: `native package --target linux`.
- Not yet done for release: CI (a `native check && native test` workflow),
  auto-update (out of scope v1), crash reporting beyond the SDK's panic
  capture, and a version bump past `0.1.0` in `app.zon`.

Design + plan live under `docs/`.
