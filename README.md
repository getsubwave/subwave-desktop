# subwave-desktop

A native desktop player for the [SUB/WAVE](https://www.getsubwave.com) internet
radio station, built on the **Vercel Native SDK** — declarative `.native` markup
+ Zig logic, drawn by the SDK's own engine (no browser, no WebView). Separate
repo from the main `subwave` monorepo; it tracks the same station HTTP API.

## Features

- **Live stream** — plays the endless Icecast stream via `fx.playAudio` with
  tune-in/out, pause, volume, session mute, and 500 ms→60 s reconnect backoff.
  **Listener-selectable format:** MP3 is the universal floor; AAC / Opus / FLAC
  mounts appear in the back panel's SIGNAL row when the station advertises
  them *and* the platform can decode them (see Codecs below).
- **Now playing** — 5 s poll of `/api/now-playing` + `/api/state` +
  `/api/session`: title, artist, album, year, genre, BPM, key, moods, energy,
  LLM-token ticker, DJ, active show, listeners, elapsed, and the masthead
  context line (show · vibe · weather).
- **Cover art** — fetches `/api/cover/:id`, registers it as the stage's square
  record sleeve (initials placeholder while it loads).
- **Real spectrum** — the SDK's FFT `.spectrum` feed (32 bands) rendered as an
  accent-themed bar analyzer with classic attack/decay ballistics.
- **Station themes** — 30 s poll of `/api/themes` repaints live via
  `DesignTokens`, with a per-listener theme override and light/dark schemes;
  the resolver (`color.zig`) converts hex / rgb() / **oklch()** /
  **color-mix(in oklab, …)** to real colors.
- **Onboarding** — first run (no saved station) is a station-address form with
  a four-step health check before tuning.
- **Station switcher** — Cmd/Ctrl+K sidebar: persisted recents (MRU, 8) plus
  the community directory (`getsubwave.com/stations.json`). A
  `SUBWAVE_STATION_URL` env var overrides the persisted station.
- **Section dial** — five stops (keys 1–5): station guide (`/api/schedule`
  show list + 7×24 week grid with day tabs), timeline (up next + history), the
  bare LIVE stage, booth feed (all/DJ/tracks filter; the DJ's latest line
  tickers on the stage), and the request slip (`POST /api/request` with an
  optional signed name + status polling).
- **Signal + sleep** — timed `/api/health` probe → latency readout while
  playing; sleep timer (15–90 min) from the tray or the back panel.
- **Mini player** — a compact secondary window (420×168) toggled from the tray.
- **Menu-bar extra** — macOS `NSStatusItem` (tray on Linux where supported):
  live now-playing rows, tune in/out, mute, sleep cycle, open player, mini
  player, quit. The red close button **hides** the main window — playback and
  the tray stay alive (one of the local SDK patches, see below).
- **Keyboard transport** — space play/pause, ↑/↓ volume, M mute, Esc back to
  LIVE, Cmd/Ctrl+K stations, 1–5 dial stops (app-level fallback; never steals
  typing from the text fields).
- **Settings persistence** — volume / theme override / stream format / station
  (+ name) / recents survive restarts (`settings.json` in the OS per-app
  config dir), saved debounced + serialized via `fx.writeFile`.

## Layout

```
app.zon                 manifest (id, platforms {macos,linux}, window 980×660)
src/
  main.zig              App wiring: shell config, key fallback, tray, mini window
  model.zig             Model / Msg / boot / update (the reducer heart) + effects
  api.zig               endpoint URL builders (pure)
  json.zig              std.json typed decoders for each payload
  color.zig             hex/rgb/oklch/color-mix → canvas.Color (OKLab math) + tests
  theme.zig             7 station tokens → DesignTokens (tokens_fn)
  spectrum.zig          band ballistics (pure) + tests
  stream_format.zig     format ↔ mount table + platform decode gate + tests
  views.zig             view registry; composes the fragments around a Zig stage
  views/*.native        onboarding, mini, player-top/-sidebar/-panel/-deck/-sheets
  icons/*.svg           app icons, registered at boot as icon="app:<name>"
  tests.zig             view build/layout contract + the pure modules' unit tests
```

The player runs entirely through the SDK **effects channel** (`.update_fx`):
timers drive polling, `fx.fetch` does HTTP, results return as typed Msgs, and
`fx.playAudio`/`registerImageBytes` handle audio + cover art. The player view
is **composed**: markup fragments around a Zig-built LIVE stage (the stage
needs `ui.image` for the square cover art, which markup deliberately excludes).

## Build & run

Requires **Zig 0.16.0** and the `@native-sdk/cli` (`npm i -g @native-sdk/cli`,
currently 0.5.3) — **plus the local SDK patches**. After every SDK
install/upgrade:

```bash
./scripts/apply-sdk-patches.sh && native test
```

The patches (comptime quota fix for large markup, close-button-hides window,
reserved tray ids) are documented in `docs/sdk-notes.md`; upstream issues
[vercel-labs/native#148](https://github.com/vercel-labs/native/issues/148) and
[#149](https://github.com/vercel-labs/native/issues/149). Symptoms of missing
patches: `native build` fails in `ui_markup.zig`, and the close button quits
the app.

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

## Codecs & the format picker

The station always serves the `/stream.mp3` floor; operators can enable
**AAC / Opus / FLAC** mounts, advertised via the `stream` flags on
`/api/now-playing`. The picker offers a mount only when the station advertises
it **and** the host engine can decode it (`stream_format.zig`):

| Codec over Icecast | macOS (AVPlayer) | Linux (GStreamer `playbin`) |
|---|---|---|
| MP3 | ✅ | ✅ |
| AAC (ADTS) | ✅ | ✅ where `gst-plugins-bad`/`libav` present |
| Ogg Opus | ❌ AVFoundation has no Ogg demuxer | ✅ offered optimistically |
| FLAC | ❌ no endless-stream FLAC | ✅ offered optimistically |

Linux offers the Ogg mounts optimistically (decode support = installed
plugins); a non-MP3 pick that keeps failing drops back to the MP3 floor after
three reconnect attempts. macOS gates are exact, so failures there stay
network-shaped and never cost the listener their stored pick.

**OS media integration.** The SDK (0.5.3) has no system now-playing or
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
- The SDK can't resize a live window — that's why the mini player is its own
  model-declared window rather than a main-window reshape.
- The FFT spectrum feed only emits while a window is actually visible on the
  glass (SDK occlusion gate) — a flat analyzer from an app launched in the
  background is not a bug; activate the app first.

## Shipping checklist

All three artifacts are built by CI. Publishing a GitHub release fires
`release: published`, and one workflow per platform builds, verifies and
uploads its asset onto that release:

| Workflow | Runner | Asset | Notes |
| --- | --- | --- | --- |
| `release-macos.yml` | `macos-15` | `.dmg` | ad-hoc signed, so first launch needs right-click → Open |
| `release-windows.yml` | `windows-latest` | `-windows-x64.zip` | built and launched on real Windows |
| `release-linux.yml` | `ubuntu-24.04` | `-linux-x64.tar.gz` | needs glibc 2.39+ and GTK4 |

Each one applies the local SDK patches before building
(`scripts/apply-sdk-patches.sh`), so a release cannot ship without them, and
each refuses to run if the tag disagrees with `.version` in `app.zon`. Shared
toolchain setup and the Zig/SDK version pins live in
`.github/actions/setup-native`.

Two runner pins are deliberate. `ubuntu-24.04` because Linux can't be
cross-compiled (the binary links the GTK4 system stack, 113 shared libraries,
nothing bundled) and because ubuntu-22.04's GTK 4.6 would compile the
fractional-HiDPI fix out — it's gated on GTK 4.12+ — and quietly ship
pixelated text. `windows-latest` because building there means the app is
actually launched on Windows under `-Dautomation=true` rather than
cross-compiled and hoped for.

`./scripts/make-release.sh --publish` still cuts a release by hand from a Mac
and remains the way to do it locally; CI then rebuilds and re-uploads the same
assets.

Linux reach: Ubuntu 24.04+, Fedora 40+, Arch. **Not** Ubuntu 22.04 or
Debian 12 (glibc 2.35/2.36) — those build from source.

Not yet done for release: a CI check on every push (these only run at release
time), signing macOS with a real Developer ID and notarizing, auto-update (out
of scope v1), crash reporting beyond the SDK's panic capture, and a version
bump past `0.1.0` in `app.zon`.

Design + plan live under `docs/`.
