# Codec picker surfacing, playback-device decision, SDK 0.7.1

Date: 2026-08-01

Three pieces of work that arrived as one question — "changing the codec and
playback device in the desktop version, can we implement this" — plus the SDK
upgrade that was pulled in alongside them.

## Starting position

**Codec picking was already built.** `src/stream_format.zig` plus the `format`
sheet in `views/player-sheets.native` give the listener MP3 / AAC / Opus /
FLAC, persisted to `settings.json`, re-tuned in place, gated by a platform
decode matrix (the Ogg-encapsulated mounts are Linux-only) and by the station's
`stream` flags on `/api/now-playing`.

Nobody sees it. The production station answers:

```json
"stream": { "mount": "/stream.mp3", "format": "mp3", "bitrate": 192,
            "opusEnabled": false, "flacEnabled": false, "aacEnabled": false }
```

With one mount advertised, `has_format_choice()` is false and the settings row
hides itself entirely. Even when a station does enable a second mount, the
control sits three presses deep: masthead gear → back panel → SIGNAL →
format sheet.

**Playback-device selection has no foothold in the SDK.** The platform seam
(`src/platform/types.zig`) exposes exactly `audio_load_fn`,
`audio_load_url_fn`, `audio_play_fn`, `audio_pause_fn`, `audio_stop_fn`,
`audio_seek_fn`, `audio_set_volume_fn`. There is no device enumeration and no
output-device property. This was re-checked against 0.7.1, the newest release:
the `*_fn` service list and the `PlatformFeature` enum are byte-identical to
0.6.0's. The SDK's own music-player reference (`examples/soundboard-ts`) drives
the same single-player `Cmd.audioPlay` surface — sound files and a seek slider,
no routing. Linux plays through a GStreamer `playbin`, macOS through AVPlayer,
Windows through Media Foundation, and none of the three hosts is given a device
to aim at.

## Decisions

1. **Codec:** surface the existing picker instead of building anything new — a
   pressable chip on the transport deck plus a settings row that is always
   present, and a sheet that names every platform-decodable format including
   the ones this station does not serve.
2. **Playback device:** do not implement. Document OS-level per-app routing and
   write the API request up for upstream. This repo deliberately carries
   exactly one local SDK patch; three more host patches (GStreamer, CoreAudio,
   Media Foundation) to carry across every upgrade is not a trade worth making
   for a feature the OS already offers on two of the three platforms.
3. **SDK:** upgrade 0.6.0 → 0.7.1 first, as its own commit.

## Part 1 — Codec picker

### Data

`src/json.zig`'s `StreamInfo` decodes only the three `*Enabled` flags today.
Add `format: ?[]const u8` and `bitrate: ?i64`. No string copying is needed:
`format` maps straight to a `StreamFormat` on the way into the model.

Two new `Model` fields, reset alongside the existing flags when the station
changes:

- `stream_bitrate: u32 = 0` — 0 means unknown
- `stream_primary: ?StreamFormat = null` — which mount that bitrate describes

The pairing is the point. The station's `bitrate` describes its *primary*
mount, the one named in `stream.mount`. If a listener picks Opus, printing
"OPUS 192k" would state a number nobody measured. The chip prints a bitrate
only when `stream_primary` equals `effectiveFormat()`, and prints the bare
label otherwise.

### Model

- `format_chip(arena)` → `"MP3 192k"`, or `"OPUS"` when the bitrate does not
  describe the effective format. Drives the deck chip.
- `format_value(arena)` → the same string, for the settings row. Replaces
  today's bare-label version.
- `format_rows(arena)` → today returns platform-decodable **and**
  station-advertised formats. It now returns every **platform-decodable**
  format, each carrying a new `available: bool`, with `detail` swapped to
  `"not served by this station"` when the station does not advertise it.
  Formats this platform cannot decode stay omitted: on macOS there is nothing
  a listener can do about FLAC, so listing it is noise.
- `pick_format` gains an availability check, so an unavailable row cannot park
  a dead value in `format_pref`. Every row keeps its `on-press` in the markup
  and `update` absorbs the ones that cannot apply — cheaper than branching the
  markup on press targets.
- `has_format_choice()` is deleted along with its entry in the exposed-field
  list. Nothing gates the row any more.

### Views

- `views/player-deck.native`: a pressable chip in the SIGNAL row
  (`on-press="open_format"`), between the signal label and the listener
  readout. A plain `<row>` with the existing `music` icon and a
  `<text size="sm">` — no new styling, inside the closed widget vocabulary the
  design brief specifies.
- `views/player-sheets.native`: drop the `<if test="{has_format_choice}">`
  wrapper around the SIGNAL row. In the format sheet the check icon becomes
  `<if test="{f.available}">`.

```
SIGNAL · GOOD          [MP3 192k]  2 listening · 84 ms
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SIGNAL / FORMAT
  MP3    universal · most reliable        ✓
  AAC    efficient · easy on data
  Opus   not served by this station
  FLAC   not served by this station
```

### Tests

`src/tests.zig` needs no new branch — the chip is unconditional. Three model
tests move:

- the existing picker test asserts `format_rows` length by station flags; it
  now asserts length by platform (4 on Linux, 2 on macOS and Windows) with the
  `available` flags flipping instead
- a new test that a pick of an unavailable format is ignored
- a new test that the chip omits the bitrate when the effective format is not
  the station's primary mount

## Part 2 — Playback device

No code. Two documents:

- `docs/sdk-audio-device-request.md` — the API request against the Native SDK
  platform seam: enumerate output devices, select one. Carries the evidence
  that 0.6.0 and 0.7.1 both lack it, and per-platform implementation notes
  (GStreamer `GstDeviceMonitor` with a pinned `pulsesink`/`pipewiresink`;
  `AVPlayer.audioOutputDeviceUniqueID` with CoreAudio enumeration;
  `IMFMediaEngineEx` audio endpoint). Written to be pasted upstream.
- A pointer from `docs/sdk-notes.md`, and a README note on routing this app's
  output elsewhere today: `pavucontrol` or PipeWire on Linux, App volume and
  device preferences on Windows. macOS has no per-app routing without a
  third-party audio driver, and the note says so.

## Part 3 — SDK 0.6.0 → 0.7.1

### Why it is safe

Diffed against what this app touches:

| Surface | 0.6.0 → 0.7.1 |
| --- | --- |
| `Effects` `pub fn` list | identical |
| `PlatformFeature` enum, `*_fn` services | identical |
| Markup vocabulary | additions only: `<code>` plus `language`, `line-numbers`, `editable`, `on-input` |
| `DesignTokens` | seven new `syntax_*` slots; `theme.zig` writes only color slots, so defaults apply |
| `app.zon` manifest | four new optional window fields (`transparent`, `always_on_top`, `click_through`, `activate_on_show`); `close_policy` unchanged |
| CLI `bin/` | byte-identical |
| `minimum_zig_version` | 0.16.0, unchanged |

Nothing removed, nothing renamed.

### The patch still matters

0.7.1's `gtk_host.c` still reads `gtk_widget_get_scale_factor()` and
`gdk_surface_get_scale_factor()` at all eight sites — upstream has not fixed
fractional HiDPI scale. A dry run of the existing patch against the 0.7.1 tree
lands all eight hunks on offset alone (+17 / +21 lines, no fuzz), which
confirms the fix is still correct there. It gets regenerated rather than
shipped on offsets, because that is what `scripts/apply-sdk-patches.sh`'s
version assertion exists to enforce.

### Touchpoints

1. `npm i -g @native-sdk/cli@0.7.1`
2. Regenerate `patches/native-sdk-local.patch` against a pristine 0.7.1 tree
   (`npm pack` → apply → re-diff) so the hunks carry 0.7.1 context
3. `scripts/apply-sdk-patches.sh` → `patch_sdk_version="0.7.1"`
4. `.github/actions/setup-native/action.yml` → `native-sdk-version` default
   `"0.7.1"`
5. `CLAUDE.md` (`0.6.0+` → `0.7.1+`) and `docs/sdk-notes.md` — record that the
   fractional-scale patch survived, and what 0.7.x added

### Ordering

The upgrade lands first, verified green on its own, before any codec work. The
canvas text-layout sources did change between the releases; if that shifts a
layout assertion in `src/tests.zig`, it should surface against an unchanged app
rather than tangled up with new UI.

## Verification

- `native test` — unit tests plus the markup build/layout contract across every
  fragment and branch
- `native check` — markup and manifest validation
- `./scripts/apply-sdk-patches.sh` run twice, to confirm the version assertion
  passes and the idempotent path reports `already applied`
- `native build -Dautomation=true`, then `native automate wait` and
  `native automate screenshot main-canvas` — eyeballing glyph antialiasing at
  167% scale is the only real proof the regenerated patch works. (`native dev`
  cannot link on this machine, so the ReleaseFast automation build is the
  verification path.)

Headless runs must not use `SUBWAVE_STATION_URL`: the env override persists the
test station into the real `settings.json`.

## Out of scope

- Enabling the Opus / AAC / FLAC mounts on the station. That is Liquidsoap,
  Icecast and Caddy configuration in the subwave monorepo, not this repo. Until
  it happens the sheet will honestly report three formats as not served.
- Any OS media-controls surface (MPRIS, MPNowPlayingInfoCenter,
  SystemMediaTransportControls). Still absent in 0.7.1; the tray extra and the
  in-window keyboard transport remain the substitutes.
