# SDK 0.8.4 upgrade and track-change notifications

Date: 2026-08-12

One question — "check what's in native sdk latest updates and update our
codebase accordingly, if anything new lets implement that improvement" — that
turns out to have exactly one actionable answer in it.

## Starting position

The app ships against `@native-sdk/cli` 0.8.0 (installed locally, pinned in
`.github/actions/setup-native/action.yml`, and the version
`scripts/apply-sdk-patches.sh` asserts its patch was generated against). npm's
`latest` is **0.8.4** — four releases published between 5 and 10 August 2026.

The whole diff was read rather than guessed at: the installed 0.8.0 tree was
compared file-by-file against a pristine `npm pack @native-sdk/cli@0.8.4`
tarball, and every surface `docs/sdk-notes.md` tracks was diffed individually.

## What 0.8.4 actually changed

### The one capability worth having: `fx.showNotification`

New on `Effects`, absent at 0.8.0:

```zig
pub fn showNotification(self: *Self, options: platform.NotificationOptions) void

pub const NotificationOptions = struct {
    title: []const u8,           // required, 1..128 bytes
    subtitle: []const u8 = "",   // optional, <=128 bytes
    body: []const u8 = "",       // optional, <=1024 bytes
};
```

Wired on **all three** platforms we ship to — `show_notification_fn` is
non-null in `src/platform/macos/root.zig`, `src/platform/windows/root.zig` and
`src/platform/linux/root.zig`, and each lists `.notifications` in its
`supportsFeature` switch. The Linux path goes through
`native_sdk_gtk_show_notification` and refuses when the web engine is not
`.system` (ours is).

Semantics that shape the design:

- **Fire-and-forget.** No result `Msg`, by deliberate design: platform
  acceptance does not mean the OS displayed it, since Focus / Do Not Disturb
  and user notification settings stay authoritative, so no success `Msg` would
  be truthful.
- **Fails closed.** Invalid or over-bound fields, a missing notification
  service, and a host refusal are all silent no-ops.
- **Synchronous on the loop thread**, where every supported desktop
  notification API expects to be entered.
- **Inert and unrecorded under fake execution and session replay.** This is the
  constraint that shapes section 3: `showNotification` returns before doing
  anything when `executor == .fake`, and unlike `windowActionState()` there is
  no `notificationState()` a test can assert against.

`"notifications"` is a manifest permission that already existed at 0.8.0 — only
the effect is new.

### New, and not for us

Audio **capture**: `startAudioCapture` / `stopAudioCapture` /
`feedAudioCapture` / `audioCaptureMsg` / `decodeAudioCaptureChannelEvent`, a
new `system_audio` manifest permission, and a new `mic.svg` built-in icon. That
is microphone input. A radio player has no use for it.

### Additive elsewhere, nothing forced

| Surface | 0.8.0 → 0.8.4 |
| --- | --- |
| `Effects` `pub fn` list | additions only (notifications, audio capture, three `feed*` test helpers) |
| `PlatformFeature` enum | identical |
| `app.zon` manifest | one new permission, `system_audio` |
| Markup vocabulary | additions only: `images` on `<markdown>`, `submit-on-enter`, `max_width`, `on_drag` — none needed here |
| Built-in icons | `mic.svg` added |
| `minimum_zig_version` | 0.16.0, unchanged |
| Trace default | still `.events` |

Nothing removed, nothing renamed, so the upgrade forces no app edits.

The README repositions TypeScript cores as the default scaffold (`native init`
now takes `--template ts-core|zig-core`, defaulting to TS). Zig stays "a
first-class app-core alternative by explicit choice and the language the
toolkit itself is built in". Existing Zig apps are unaffected — this is
documentation and scaffolding, not a runtime change.

### Re-checked negatives

Grepped for, not assumed. Still **no** OS media-controls surface anywhere in
the 0.8.4 tree (no MPRIS, no `MPNowPlayingInfoCenter`, no
`SystemMediaTransportControls`), and still **no** audio output-device API — the
platform seam remains load / play / pause / stop / seek / volume with no
enumeration and no device property. Both CLAUDE.md gotchas stand.
`docs/sdk-audio-device-request.md` stays open upstream.

## 1. The SDK upgrade

Mechanical, and it follows the ordered ritual already written down in
`docs/sdk-notes.md`.

```bash
npm i -g @native-sdk/cli@0.8.4
./scripts/apply-sdk-patches.sh          # fails: patch says 0.8.0, install says 0.8.4
```

That failure is the design working — a unified diff carries no version of its
own, so the script refuses to land hunks on a release nobody checked.

**The HiDPI patch is still needed.** `gtk_host.c` moved (~80 changed lines) but
every one of the seven scale-reporting sites still reads an integer API:
`gtk_widget_get_scale_factor()` at four sites and `gdk_surface_get_scale_factor()`
— the *integer* GDK entry point, not the fractional `gdk_surface_get_scale()` —
at three. [vercel-labs/native#156] is still open. Because the file moved, the
old hunks will not land clean, so the patch must be regenerated against the
pristine 0.8.4 tarball rather than force-applied.

[vercel-labs/native#156]: https://github.com/vercel-labs/native/issues/156

Then bump **both** pins, which must agree:

- `patch_sdk_version` in `scripts/apply-sdk-patches.sh` (what the patch was
  generated against)
- `native-sdk-version` in `.github/actions/setup-native/action.yml` (what CI
  installs)

Skipping the second is how CI ends up installing an SDK the app no longer
builds against, which is exactly what happened on the 0.6.0 upgrade.

`-Dtrace=off` stays mandatory: `build.zig` still defaults `-Dtrace` to
`.events`, so `scripts/check-release-flags.sh` keeps its job.

Verify the patch took, on a fractional-scale display:

```bash
native automate wait | grep -o 'gpu_scale=[0-9.]*'   # 1.6666666, not 2
```

and then `native test` for the suite.

## 2. Track-change notifications

The feature `showNotification` unlocks, and the closest this SDK gets to a Now
Playing surface while OS media controls remain absent: when a new song starts
and you are not looking at the player, a desktop toast tells you what it is.

### Manifest

Add `"notifications"` to `app.zon`'s `.permissions` (currently
`.{ "view", "command" }`).

### Model

Two new fields:

- `notify_track: bool = false` — the listener's opt-in, persisted as
  `notifyTrack` in settings.json. Mirrors `discord_enabled` exactly: applied in
  `applySettingsJson`, written by the `saveSettings` printer, flipped by a new
  `toggle_notify` Msg.
- `app_active: bool = true` — set by the **existing** `.app_activated` /
  `.app_deactivated` arms at `src/model.zig:2997`. Those Msgs already arrive
  (SDK 0.6.0 `on_lifecycle`); nothing new is wired to produce them.

### The decision, as a pure function

This is the part that gets tested, because the effect itself cannot be
(see section 3):

```zig
/// Background-only, on-air-only, and never the first fill.
pub fn shouldNotifyTrack(self: *const Model) bool {
    return self.notify_track
        and !self.app_active   // new: foreground means the stage already shows it
        and self.on_air()      // existing: playing, not failed, not buffering, online
        and self.has_track();  // existing: suppresses the "" -> title first fill
}
```

Each clause earns its place:

- `notify_track` — opt-in, off by default (below).
- `!app_active` — if the player is on screen the LIVE stage already shows the
  track; a toast would repeat it every three minutes.
- `on_air()` — no toasts while tuned out, buffering, or failed. The station
  keeps airing music whether or not you are listening; the app is a player, not
  a ticker.
- `has_track()` — the `.got_np` handler sets `track_changed = true` on the very
  first fetch, because the title flips from `""` to the track name. That is a
  first fill, not a track change, and must not fire a toast at launch.

### The call site

Three lines inside the existing `track_changed` branch of `.got_np`
(`src/model.zig:2294`), placed after the title/artist/show buffers are filled
so the notification carries the new track rather than the old one:

```zig
if (track_changed and model.shouldNotifyTrack()) {
    fx.showNotification(.{
        .title = model.title,
        .subtitle = model.artist,
        .body = model.show,
    });
}
```

The track is the `title` because all three platforms supply the app name as the
notification header themselves — putting "SUBWAVE" in the title would render it
twice. `body` carries the show name, which is `""` when there is no active show
and is an allowed empty optional.

All three fields are well inside the 128 / 128 / 1024 byte bounds: they are
slices into the Model's fixed `*_store` buffers, whose sizes already cap them
far below.

### UI

An inline `<switch>` row in the back panel (`src/views/player-sheets.native`)
under a new `NOTIFICATIONS` section label, sitting between SIGNAL and
INTEGRATIONS. It follows the shape of the switch already inside the Discord
sheet:

```
<use template="section-label" title="NOTIFICATIONS"/>
<row main="space_between" cross="center" padding="10" label="Track notifications">
  <row gap="10" cross="center">
    <icon name="bell" width="16" height="16" foreground="text_muted"/>
    <text>Track notifications</text>
  </row>
  <switch selected="{notify_track}" on-toggle="toggle_notify" label="Track notifications"/>
</row>
```

Not a sub-sheet like Discord Rich Presence: Discord needs a client ID entered
and validated, so it earns a sheet. This needs nothing, so the switch belongs
directly in the settings list.

`bell` is used if it is in the SDK's closed compile-checked icon set — the
compiler decides, since markup `<icon>` names are validated at comptime. If it
is not, the fallback is a registered app SVG in `src/icons/` reached as
`icon="app:bell"`, which is the same path `app:radio` already takes on the
Discord row.

### Default: off

Existing installs have no `notifyTrack` key in settings.json, so they land on
the `false` default and nothing changes for them until they flip the switch. A
desktop notification is an OS-level interruption; starting to produce one every
few minutes in an update nobody opted into is a bug report waiting to happen.

## 3. Testing

The constraint is stated once because it drives the whole shape:
`fx.showNotification` is **inert under fake execution and unrecorded**, so no
test can observe that the call happened. That is why `shouldNotifyTrack` is a
pure predicate on the Model rather than logic inlined at the call site.

- Unit tests on `shouldNotifyTrack` exercising each gate independently: toggle
  off, app foregrounded, tuned out, buffering, and the first-fill case where
  `has_track()` is false.
- A settings round-trip test for `notifyTrack`, mirroring the existing
  `"discord settings round-trip through applySettingsJson"` test.
- `src/tests.zig` builds and lays out every view fragment across all
  tab/sheet/phase branches, so the new panel row is covered the moment it
  exists, and a Model field drift stays a compile error.
- The `fx.showNotification` call itself is a thin untested tail: one statement,
  no branching, every argument already validated by the SDK.

Verification beyond the suite: build with `-Dautomation=true -Dtrace=off`, turn
the switch on, defocus the app, and wait for a track flip on the live station.

## 4. Docs and CI

- **`docs/sdk-notes.md`** — a "What 0.8.4 changed" section in the established
  table format: notifications landed and are used, audio capture landed and is
  not, the HiDPI patch survived and was regenerated (with the seven still-integer
  sites named), `-Dtrace=off` re-confirmed mandatory, and the re-checked
  negatives on media controls and output devices.
- **`CLAUDE.md`** — bump the global CLI floor from 0.8.0+ to 0.8.4+, and revise
  the media-controls gotcha, which is no longer flatly true: there is still no
  MPRIS / MPNowPlayingInfoCenter / SMTC and no hardware media keys, but the
  substitutes list now includes a track toast alongside the tray extra and the
  in-window keyboard transport.
- **`README.md`** — track notifications in the features list.
- **`.github/actions/setup-native/action.yml`** — `native-sdk-version` to 0.8.4.

## Out of scope

- Audio capture and the `system_audio` permission. Mic input has no place in a
  radio player.
- The new markup attributes (`images`, `submit-on-enter`, `max_width`,
  `on_drag`). No existing view is waiting on any of them; adopting them for
  their own sake is churn.
- A TypeScript core. The README's repositioning changes nothing about a Zig app
  that already works.
- Any local patch for output-device selection or media controls. The reasoning
  in `docs/sdk-notes.md` stands: carrying more host patches across every SDK
  upgrade is a bad trade against the one HiDPI patch we cannot avoid.
