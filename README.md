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
- **Update notice** — a daily GitHub Releases poll; a newer version lights a
  SERVICE row in the back panel (and a dot by the settings button) that opens
  the release page in the browser. No auto-install.
- **Now playing** — 5 s poll of `/api/now-playing` + `/api/state` +
  `/api/session`: title, artist, album, year, genre, BPM, key, moods, energy,
  LLM-token ticker, DJ, active show, listeners, elapsed, and the masthead
  context line (show · vibe · weather).
- **Cover art** — `fx.loadImage` pulls `/api/cover/:id` and decodes it off the
  loop thread into the stage's square record sleeve (initials placeholder while
  it loads), keeping a disk cache under the OS caches dir so a track that aired
  recently comes back without touching the network.
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
- **Section dial** — a segmented tab strip of five stops (keys 1–5) sharing one
  track, the active stop filled with the station accent: station guide (`/api/schedule`
  show list + 7×24 week grid with day tabs), timeline (up next + history), the
  bare LIVE stage, booth feed (all/DJ/tracks filter; the DJ's latest line
  tickers on the stage), and the request slip (`POST /api/request` with an
  optional signed name + status polling).
- **Signal + sleep** — timed `/api/health` probe → latency readout while
  playing; sleep timer (15–90 min) from the tray or the back panel.
- **Mini player** — a compact secondary window (420×168) toggled from the tray
  or Cmd/Ctrl+Shift+M. One player surface at a time: opening it minimizes the
  full player, and EXPAND — or closing the mini window — brings the full
  player back.
- **Menu-bar extra** — macOS `NSStatusItem` and the Windows tray (the GTK host
  still has none): live now-playing rows, tune in/out, mute, sleep cycle, open
  player, mini player, quit. On macOS and Windows the close button **hides** the
  main window — playback and the tray stay alive — via `app.zon`'s
  `close_policy`; on Linux it quits, because there is no tray to bring a hidden
  window back (see `docs/sdk-notes.md`).
- **Keyboard transport** — space play/pause, ↑/↓ volume, M mute, L like the
  current track, Esc back to LIVE, Cmd/Ctrl+K stations, Cmd/Ctrl+Shift+M mini
  player, 1–5 dial stops (app-level fallback; never steals typing from the
  text fields).
- **Settings persistence** — volume / theme override / stream format / station
  (+ name) / recents survive restarts (`settings.json` in the OS per-app
  config dir), saved debounced + serialized via `fx.writeFile`.
- **Discord Rich Presence** — opt-in; shows the current track/artist (title
  clickable through to the station, cover art included) on your Discord
  profile while the SDK's `fx.spawn` drives a small self-relaunched helper
  (`--discord-rpc-helper`) that owns the local Discord IPC socket. Requires
  a client ID in `discord.zon` (see below) — ships disabled otherwise.

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
  views.zig             view registry; composes the markup fragments
  views/*.native        onboarding, mini, player-top/-sidebar/-stage/-panel/-deck/-sheets
  icons/*.svg           app icons, registered at boot as icon="app:<name>"
  tests.zig             view build/layout contract + the pure modules' unit tests
```

The player runs entirely through the SDK **effects channel** (`.update_fx`):
timers drive polling, `fx.fetch` does HTTP, results return as typed Msgs, and
`fx.playAudio`/`fx.loadImage` handle audio + cover art. Every player view is
markup — `views.zig` only composes the fragments, deciding which conditional
ones appear.

## Build & run

Requires **Zig 0.16.0** and `@native-sdk/cli` **0.6.0+**
(`npm i -g @native-sdk/cli`) — **plus one local SDK patch**. After every SDK
install/upgrade:

```bash
./scripts/apply-sdk-patches.sh && native test
```

The remaining patch fixes fractional-HiDPI text rendering on Linux
([vercel-labs/native#156](https://github.com/vercel-labs/native/issues/156));
it is documented in `docs/sdk-notes.md`. Symptom of a missing patch: pixelated
text on a fractional-scale display. (0.6.0 absorbed the two older patches — the
comptime quota fix and close-button-hides-window.)

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

### Discord Rich Presence setup (optional)

Discord Rich Presence needs an application client ID. Create one at
[discord.com/developers/applications](https://discord.com/developers/applications),
then fill it into `src/discord.zon`:

```zig
.{
    .client_id = "your-application-id-here",
}
```

Leave it empty (the checked-in default) to ship without the feature — the
settings sheet shows it as unconfigured rather than hiding it, and no
Discord IPC connection is ever attempted.

## Codecs & the format picker

The station always serves the `/stream.mp3` floor; operators can enable
**AAC / Opus / FLAC** mounts, advertised via the `stream` flags on
`/api/now-playing`. The picker offers a mount only when the station advertises
it **and** the host engine can decode it (`stream_format.zig`):

| Codec over Icecast | macOS (AVPlayer) | Windows (Media Foundation) | Linux (GStreamer `playbin`) |
|---|---|---|---|
| MP3 | ✅ | ✅ | ✅ |
| AAC (ADTS) | ✅ | ✅ | ✅ where `gst-plugins-bad`/`libav` present |
| Ogg Opus | ❌ AVFoundation has no Ogg demuxer | ❌ no Ogg demuxer | ✅ offered optimistically |
| FLAC | ❌ no endless-stream FLAC | ❌ no endless-stream FLAC | ✅ offered optimistically |

Linux offers the Ogg mounts optimistically (decode support = installed
plugins); a non-MP3 pick that keeps failing drops back to the MP3 floor after
three reconnect attempts. macOS and Windows gates are exact, so failures there
stay network-shaped and never cost the listener their stored pick.

Windows was absent from this table until 0.2.0 and fell through to an MP3-only
default, so its builds shipped with no AAC and a hidden format picker. Nothing
caught it because cross-compiling the Windows binary never ran the test suite
for the target; building on a Windows runner did, immediately.

**OS media integration.** The SDK (re-checked at 0.6.0) has no system
now-playing or media-key surface — no `MPNowPlayingInfoCenter`/
`MPRemoteCommandCenter` on macOS, no MPRIS on Linux — so hardware play/pause
keys and the OS Now Playing widget can't be wired up yet (SDK feature request).
What IS wired up: the menu-bar status item (macOS and Windows; the GTK host has
no tray, so Linux gets neither the extra nor close-to-hide), the in-window keyboard
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

All four artifacts are built by CI. Publishing a GitHub release fires
`release: published`, and one workflow per platform builds, verifies and
uploads its asset onto that release (the macOS workflow is a two-leg matrix,
one per CPU flavor):

| Workflow | Runner | Asset | Notes |
| --- | --- | --- | --- |
| `release-macos.yml` | `macos-15` | `.dmg` | Apple Silicon; ad-hoc signed, so first launch needs right-click → Open |
| `release-macos.yml` | `macos-15-intel` | `-intel.dmg` | Intel (x86_64), built and tested natively; label supported until Aug 2027 |
| `release-windows.yml` | `windows-latest` | `-windows-x64.zip` | built and launched on real Windows |
| `release-linux.yml` | `ubuntu-24.04` | `-linux-x64.tar.gz` | needs glibc 2.39+ and GTK4 |

Each one applies the local SDK patch before building
(`scripts/apply-sdk-patches.sh`), so a release cannot ship without it, and
each refuses to run if the tag disagrees with `.version` in `app.zon`. The
macOS and Windows legs additionally run `scripts/set-close-policy.sh hide`
before testing, which is how those builds get the menu-bar close semantics that
`app.zon` cannot declare for all three targets at once. Shared
toolchain setup and the Zig/SDK version pins live in
`.github/actions/setup-native`.

Every release build passes `-Dcpu=baseline`, and that flag is load bearing: a
plain `native build` bakes the CI runner's CPU features into the binary, which
is how v0.2.1's Windows exe shipped requiring AVX-512 and silently failed to
start on most machines. `scripts/audit-cpu-baseline.sh` disassembles each
shipped x86-64 artifact in CI and fails the leg if the pin ever regresses.

Two runner pins are deliberate. `ubuntu-24.04` because Linux can't be
cross-compiled (the binary links the GTK4 system stack, 113 shared libraries,
nothing bundled) and because ubuntu-22.04's GTK 4.6 would compile the
fractional-HiDPI fix out — it's gated on GTK 4.12+ — and quietly ship
pixelated text. `windows-latest` because building there means the app is
actually launched on Windows under `-Dautomation=true` rather than
cross-compiled and hoped for.

`./scripts/make-release.sh` is the way to cut one. It builds nothing itself:
it checks that main is clean, in sync, on an unused tag and **already green in
CI on that exact commit**, then creates the release and follows the three runs
until every asset is attached (four in all — the macOS run uploads two DMGs).
Since nothing is built locally, a release can be cut from any machine.

Every push to main and every pull request also runs `native check`, `native
test` and `native build` on every release platform, both macOS CPU flavors
included (`.github/workflows/ci.yml`).
Platform-specific code can only be tested where it runs — a decode-gate bug
shipped from 0.1.0 to 0.2.0 because Windows was only ever cross-compiled, and
cross-compiling never runs the target's suite.

Linux reach: Ubuntu 24.04+, Fedora 40+, Arch. **Not** Ubuntu 22.04 or
Debian 12 (glibc 2.35/2.36) — those build from source.

Not yet done for release: a CI check on every push (these only run at release
time), signing macOS with a real Developer ID and notarizing, auto-update (out
of scope v1), crash reporting beyond the SDK's panic capture, and a version
bump past `0.1.0` in `app.zon`.

Design + plan live under `docs/`.
