# SUB/WAVE Native Desktop Player (`subwave-desktop`) — Plan

## Context

SUB/WAVE today has two listener clients: the Next.js **web player** (`web/`) and an
**Expo/React-Native** app (`app/`). Both are player-for-any-station clients that poll a
CORS-open, no-auth HTTP API and play an Icecast MP3 stream. There is no true **native
desktop** player, and the RN app's visualiser is a *synthesised* spectrum (RNTP exposes
no analyser on a raw Icecast MP3 — `app/src/hooks/useSpectrum.ts`).

Vercel Labs' **Native SDK** (github.com/vercel-labs/native, v0.4.4, pre-1.0) is a strong
fit: declarative `.native` markup + Zig logic + its own renderer (no browser/WebView).
Exploration confirmed it offers exactly what a radio player needs — first-class audio
(`fx.playAudio` streams a URL; pause/resume/volume), a **real FFT spectrum** feed (32
bands via the audio event channel), HTTP + timers through an Elm-style effects channel,
and a `DesignTokens` theming system that reskins **wholesale without touching layout
markup**. Its shipped `deck` and `soundboard` examples are two music players that differ
only by tokens + chrome — i.e. "player with skins" is a demonstrated pattern.

**Outcome:** a native desktop player for macOS + Linux that plays the live stream, shows
now-playing / timeline / booth / schedule, submits requests, renders a real spectrum
visualiser, and is **skinnable** on two axes — live station themes *and* selectable app
chrome (Deck vs Card). Built de-risked: a gating audio spike proves the endless stream
plays before we commit to the full build.

## Decisions (locked with the user)

| Fork | Decision |
|---|---|
| Approach | **Spike first, then commit** — Phase 0 proves endless-stream playback before the full build. |
| Platform | **Linux + macOS together.** Linux (Arch) is the primary local dev box; macOS is the SDK's deepest surface (AVPlayer) and needs Mac access to build/run. |
| Skins | **2 app chromes + live station themes.** `Deck` (compact chromeless hi-fi strip) and `Card` (standard window, now-playing card + tabs); both honor the station's 7-token `/api/themes`. |
| Location | **Separate repo `subwave-desktop`** — isolates the Zig/Native toolchain from the Node monorepo. |

## Prerequisites (bootstrap, gated at Phase 0)

- **Zig 0.16.0** and **`@native-sdk/cli`** (`npm i -g @native-sdk/cli`) — neither installed here. Not installable in plan mode; first execution step.
- **macOS access** to build/run the mac target (local Mac or a CI mac runner). Linux dev proceeds without it.
- A reachable SUB/WAVE station for live verification: the public station, or a local dev stack (`subwave-control` / `subwave-worktree-dev`) with `SUBWAVE_STATION_URL=http://localhost:<port>`.

## Architecture

### Verified SDK primitives (confirmed from SDK source/docs — the only ones the design leans on)

- App wiring: `.init_fx = boot`, `.update_fx = update`, `.tokens_fn = tokensFn`, `.view = view` (`examples/system-monitor`).
- Reducer: `pub fn update(model: *Model, msg: Msg, fx: *Effects) void`; `Effects = native_sdk.UiApp(Model, Msg).Effects`.
- Timer: `fx.startTimer(.{ .key, .interval_ms, .mode = .repeating|.oneshot, .on_fire = Effects.timerMsg(.tag) })` → `EffectTimer{ outcome == .fired }`.
- **HTTP: `fx.fetch(.{ .key, .url, .on_response = Effects.responseMsg(.tag) })`** → `EffectResponse{ outcome ∈ {ok,rejected,connect_failed,tls_failed,protocol_failed,timed_out,cancelled}, status, body }`; body ≤ 256 KiB; 30 s default; `fx.cancel(key)`. (POST field names for method/headers/body: confirm before Phase 6 — see open questions.)
- Files: `fx.readFile` / `fx.writeFile` (settings persistence). Subprocess: `fx.spawn` (proxy fallback).
- Audio: `fx.playAudio(.{ .key, .url, [.path,.cache_path,.expected_bytes], .on_event = Effects.audioMsg(.tag) })`, `pauseAudio/resumeAudio/stopAudio/seekAudio/setAudioVolume`; `EffectAudio.kind ∈ {loaded, position, spectrum, completed, failed, rejected}` (spectrum rides this same channel: 32 bands, 50 Hz–16 kHz, ~25 Hz).
- Theming: `canvas.DesignTokens.theme(cfg)`, `themeWithOverrides(base, overrides)`, sparse `DesignTokenOverrides`, `canvas.Color.rgb8/rgba8`. "Every component reads one DesignTokens value; no per-component style props."
- Manifest: `app.zon` `.shell.windows[{label,title,width,height,resizable,titlebar,views}]`, `.theme`, `.shortcuts`, `.platforms`, `.permissions`.
- Automation: `native build -Dautomation=true`; `native automate wait|assert '<regex>'|widget-click|screenshot|shortcut`; `native check`; `native test`.

### Two-layer skin model — the heart of "skins"

Two orthogonal axes, composed at a single point.

- **Layer B — App Skin (chrome + material + window):** a Zig unit `{ id, base: fn(scheme,hc,rm)→DesignTokens, window, root_view }`. Owns a base token pack (controls/metrics/typography/radius/shadow — the non-color "material"), a `.native` markup set, and a window config (size + `titlebar` chromeless vs standard). `Deck` and `Card` are two such units (forks of `examples/deck` and `examples/soundboard`).
- **Layer A — Station Theme (live colors):** the 7 tokens from `GET /api/themes` (`--bg --ink --muted --accent --overlay --soft-border --field` + `mode`) resolved to `canvas.Color` and projected onto color slots only: `bg→page`, `field→surface`, `ink→text`, `muted→text_muted`, `accent→accent+focus`, `overlay→shadow/scrim`, `soft-border→stroke`, `mode→color_scheme`.
- **Composition (A over B) — the one reskin point** in `tokensFn(model)`:
  ```zig
  pub fn tokensFn(model: *const Model) canvas.DesignTokens {
      const skin = skins.active(model.skin_id);                 // Layer B material
      const base = skin.base(model.scheme, model.high_contrast, model.reduce_motion);
      if (model.high_contrast) return base;                     // a11y wins
      return canvas.DesignTokens.applyOverrides(base, theme.stationOverrides(model.colors, model.scheme));
  }
  ```
  The runtime re-reads `tokensFn` on model change, so a live `/api/themes` change or a skin switch reskins with **zero markup edits**. Per-listener override precedence mirrors the RN app: `override ?? station.active ?? themes[0]`.

### Project structure (`subwave-desktop/` repo root)

```
app.zon            Manifest: id dev.subwave.player; platforms {macos,linux(,windows)};
                   two windows (deck chromeless 512×264, card standard 1080×720); shortcuts; base theme.
build.zig(.zon)    From `native init` + @native-sdk dep, test & automation steps.
README.md          Dev/run/verify + SUBWAVE_STATION_URL.
assets/            Icons, fonts.
src/
  main.zig         Wiring only (register Model/init_fx/update_fx/tokens_fn/view).
  model.zig        Model struct + Msg union + update() reducer + boot(). The heart.
  effects.zig      Thin fx.* wrappers + the u64 effect-key registry (single place issuing effects).
  api.zig          Base config + normalizeBase + basic-auth split + URL builders. Pure. (port of app/src/lib/api.ts)
  json.zig         std.json typed decoders: NowPlaying, StationState, Session, Schedule, ThemesPayload, RequestResult. Pure.
  color.zig        Resolver (bytes,mode)→canvas.Color for hex/rgb/oklch/color-mix + mode-aware fallback. Pure. THE risk-(ii) module.
  theme.zig        stationOverrides(colors,scheme)→DesignTokenOverrides; tokensFn(model).
  skins.zig        AppSkin registry + active() + base packs (deck/card material).
  view.zig         Top view() → active skin's root.
  spectrum.zig     Band ballistics (instant attack / linear decay). Port of deck.
  feed.zig         Now-playing/state merge: trackStartedAt from current.startedAt, OFFLINE_CONFIRM_POLLS, setIfChanged. Pure. (port of web/hooks/useStationFeed.ts)
  skins/deck/root.native, skins/card/root.native
  partials/nowplaying.native, spectrum.native, transport.native, request_panel.native, theme_picker.native, header.native
  fixtures/        Committed real API JSON + real oklch/color-mix theme strings.
  tests.zig        native test entry: json, color, api, feed, spectrum against fixtures.
```
Split rationale (per `examples/system-monitor`): pure `(bytes)→struct` modules are fixture-tested with zero effects; the effectful half lives in `model.zig`/`effects.zig`.

### Core loops (condensed)

- **Boot (`init_fx`):** resolve base (`SUBWAVE_STATION_URL` env → persisted settings → default); `fx.readFile` settings; **start the live stream** (`fx.playAudio(.{.url = "<base>/stream.mp3", .on_event=…})`, deliberately omitting `.expected_bytes`/`.cache_path`); arm two repeating timers (feed 5 s, theme 30 s); fire immediate first fetches.
- **Feed loop (5 s):** three parallel `fx.fetch` (np/state/session). `got_np`→parse→`feed.applyNowPlaying` + offline debounce (4 polls); `got_state`→`feed.applyTrackStart` (elapsed derived per-frame from `current.startedAt`, not stored per second). Fail-soft: non-200 retries next tick.
- **Theme loop (30 s):** `got_themes`→pick active (override precedence)→`color.resolve` each of the 7 tokens for `mode`→store in `model.colors`; next paint restamps via `tokensFn`.
- **Transport:** `toggle_play`→`fx.pauseAudio`/`resumeAudio`; `volume_changed`→`fx.setAudioVolume`+debounced settings save; `tune_out`→`fx.stopAudio`. `seekAudio` unused (live stream, no seek → Card hides scrubber).
- **Audio/spectrum events:** `.loaded/.position`→clear failure + reset backoff; `.spectrum`→`spectrum.setTargets`; `.failed/.rejected`→`scheduleReconnect`. Per-frame `frame_clock`→`spectrum.decay` + marquee.
- **Reconnect:** 500 ms→60 s exponential backoff oneshot timer, re-issue `playAudio` with `?t=` cache-buster (port of `web/hooks/usePlayer.ts`).
- **Requests:** `submit_request`→`fx.fetch` POST `/api/request`→`got_reqpost` stores `requestId`→2 s oneshot poll `/api/request/:id` until terminal status.

## The two hard risks

### Risk (i) — endless Icecast stream vs `fx.playAudio` (Phase 0 gate)
The `deck` example targets **finite files** (`.expected_bytes`, disk cache verified against per-track byte length). An Icecast mount has no Content-Length. The *backend* is fine (Linux GStreamer, macOS AVPlayer, Windows MF all stream endless HTTP audio); the question is whether the **SDK wrapper** forces the finite path.

**Spike:** throwaway app calling `fx.playAudio(.{ .url="<station>/stream.mp3", .on_event=… })` with `.path`/`.cache_path`/`.expected_bytes` OMITTED; log every audio event. **Pass** = `.loaded` then continuous `.position`/`.spectrum` for ≥10 min, no `.failed`, flat memory, no unbounded cache growth. Run Linux first, then macOS.

**Fallback ladder** (first that works wins): (1) native live path as above; (2) bounded/ring-buffer `cache_path` if one is required; (3) **local re-serve proxy** via `fx.spawn` (ffmpeg/gstreamer or a tiny Zig/Go relay pulling the stream and re-serving on `127.0.0.1`); (4) upstream a `.live=true` flag request, ship on (3) meanwhile. Reconnect backoff applies regardless.

### Risk (ii) — oklch/color-mix resolution (`src/color.zig`)
`/api/themes` values may be `#hex`, `rgb()`, `oklch()`, or `color-mix()`; `Color.rgb8` takes integer RGB. The desktop app **converts** (not just falls back like the RN `safeColor`): tier order = (1) hex, (2) rgb/rgba, (3) oklch→OKLab→linear sRGB→gamma, gamut-clamp (~40 lines, no alloc), (4) color-mix (recursive resolve + weighted mix in named space), (5) unknown → **mode-aware** hex default (`LIGHT_DEFAULTS`/`DARK_DEFAULTS`, the exact seeded values at `app/src/theme/ThemeContext.tsx:40-63`, preserving the never-fall-light-to-dark bug fix). Pure module → fixture-tested under `native test`, including a light theme whose `--bg`/`--field` are oklch and `--ink` is hex.

## Reuse (port these existing files, don't reinvent)

- `web/hooks/usePlayer.ts` — stream reconnect/backoff, `?t=` cache-buster, idle tune-out → audio/reconnect arms.
- `web/hooks/useStationFeed.ts` — 5 s feed-merge semantics (trackStartedAt from `current.startedAt`, OFFLINE_CONFIRM_POLLS, setIfChanged) → `feed.zig`.
- `app/src/lib/api.ts` — URL shape, `normalizeBase`/`splitCredentials`, stream headers → `api.zig`.
- `app/src/theme/ThemeContext.tsx` — 7-token mapping, mode-aware LIGHT/DARK defaults, oklch/color-mix fallback contract → `color.zig` must preserve and extend it.
- SDK templates to fork: `examples/deck` (Deck skin: audio, spectrum, marquee, chromeless window, material tokens in `src/theme.zig`) and `examples/soundboard` (Card skin: album grid, cover art, `nowplaying.native`/`header.native`).

## Verification & dev workflow

- **Scaffold:** `native init` in the new repo. **Dev:** `native dev` (hot-reloads markup + Zig) against a live/local station. **Check:** `native check`.
- **Unit/fixture:** `native test` runs `src/tests.zig` — locks `json`, `color` (oklch resolver), `api`, `feed`, `spectrum` against committed fixtures, no running station needed.
- **Agent-driven UI:** `native build -Dautomation=true` → `native automate wait` → `assert 'NOW PLAYING.*<title>'` → `widget-click <play>` / `shortcut deck.play-pause` → `screenshot <canvas>` across a light theme, a dark theme, and an oklch theme for reskin regression. Every interactive widget gets an `accessibility_label`.
- **Station target:** `boot()` resolves `SUBWAVE_STATION_URL` env → persisted settings → default; a Settings/onboarding view writes it.
- **CI:** `native check` + `native test` + an automation smoke against a seeded local station, per platform (Linux + macOS).

## Phasing (dependency- and de-risk-ordered)

| Phase | Deliverable | Gate |
|---|---|---|
| **0. Audio spike** | Toolchain install; throwaway `playAudio(url)` on endless `/stream.mp3`, 10-min soak Linux+macOS; choose fallback rung. | **Blocks everything.** Endless stream plays or proxy decided. |
| **1. Hello player** | `native init`; one window; live stream + play/pause/volume + reconnect backoff; 5 s `/now-playing` → title/artist text. | Audio + feed end-to-end. |
| **2. Station themes** | `color.zig` + fixtures + `native test`; 30 s `/api/themes`; `tokensFn` overrides; live reskin on hex + dark-oklch + light-oklch/color-mix. | Resolver correct; reskin without markup change. |
| **3. Full Deck skin** | Marquee, cover art, elapsed from `startedAt`, listeners, DJ/activeShow, offline/BUFFERING/STREAM-LOST states. | One shippable skin. |
| **4. Card skin + switch** | Second window/material; `skins.zig` switch; both honor station themes; composition tests. | Two-layer model proven. |
| **5. Spectrum** | Subscribe `.spectrum`; ballistics in `spectrum.zig`; `spectrum.native` bars; noise-floor idle comb. | Visualiser live. |
| **6. Requests + schedule + booth** | `/request` POST→poll panel; `/schedule` view; `/session` feed. | Interaction complete. |
| **7. Packaging** | `native build` per-platform (macOS + Linux GStreamer); icons; settings persistence + station onboarding; mac sign/notarize; CI smoke. | Distributable. |

## Out of scope (v1)

Opus/FLAC/AAC streams (MP3-only, same chained-Ogg reasons as web); multi-station library/switcher UI (single configured station, base still runtime-configurable); track seek/scrub and offline caching; booth write actions beyond song request; theme-authoring UI; embedded WebView content; auto-update; Windows as a first-class target (SDK supports it, deferred behind mac+Linux); mobile targets; color spaces beyond hex/rgb/oklch/color-mix.

## Open questions (carried into Phase 0/1 — none block the architecture)

1. **Endless-stream support in `fx.playAudio`** — resolved by the Phase 0 spike (highest priority).
2. **`fx.fetch` POST shape** — confirm exact `.method`/`.headers`/`.body` field names before Phase 6 (`examples/notes`/`kanban`/`command-app`).
3. **Cover art URL → `canvas.ImageId`** — the URL-load-and-decode path for `/api/cover/:id` (mind the 256 KiB fetch body cap). Affects Phase 3.
4. **Runtime window-shape switching** — both windows declared in `app.zon`; confirm show/hide-window ops (fallback: one resizable window, two view roots). Affects Phase 4.
5. **Basic-auth stream** — does `fx.playAudio` accept request headers, or must creds ride URL userinfo (GStreamer supports it)? Affects Phase 1 edge.
6. **Automation over gpu_surface** — confirm the accessibility tree exposes canvas widgets by label; else lean on screenshot diffing.

## Note on execution

This creates a **new repo** (`subwave-desktop`) with a Zig toolchain — it will not be built inside the current `subwave` worktree. The API-contract reuse pointers above stay in the `subwave` monorepo; this plan (and a copy of the design) should be committed into `subwave-desktop/docs/` when it is scaffolded.
