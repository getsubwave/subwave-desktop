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

## Notes & follow-ups

- **Audio playback works on Linux** (GTK + GStreamer) in this SDK build, despite
  the docs marking GTK/Win32 audio as unsupported. macOS uses AVFoundation.
- `model.zig` `boot_volume` is **0.0** (muted) so automated runs don't play out
  loud — set it to `0.8` for real listening. Audio still decodes; the spectrum
  and elapsed still report while muted.
- **Gotcha:** a `/` in the *scene* window title crashes GTK at `app_start`; keep
  the branded slash out of `app.zon`/`shell_windows` titles (it's fine in
  `runWithOptions.window_title`).
- **Not yet done:** settings persistence (skin/volume across restarts — the SDK's
  config-dir path story in the TEA model needs sorting), a runtime station
  switcher UI (the base URL is a compile-time default today; the API contract is
  fully factored in `api.zig` for a runtime refactor), a per-skin window shape
  (Deck as a chromeless strip window), and a branded disc icon.

Design + plan live under `docs/`.
