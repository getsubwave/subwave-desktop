# SDK 0.8.4 Upgrade and Track-Change Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the Native SDK from 0.8.0 to 0.8.4 and use its one new
useful capability — `fx.showNotification` — to post a desktop toast when the
station's track changes while the app is in the background.

**Architecture:** The SDK upgrade is mechanical and forces no app edits
(`Effects` is additive, `PlatformFeature` unchanged), but the Linux HiDPI patch
must be regenerated because `gtk_host.c` moved. The feature is Elm-style like
everything else: two new `Model` fields, one pure predicate `shouldNotifyTrack`
that carries all the decision logic (because the effect itself is unobservable
in tests), and a three-line fire-and-forget call in the existing `track_changed`
branch of the `.got_np` reducer arm.

**Tech Stack:** Zig 0.16.0, `@native-sdk/cli` 0.8.4, declarative `.native`
markup, no heap ownership in the model (fixed `*_store` buffers).

## Global Constraints

- Zig **0.16.0**; global `@native-sdk/cli` **0.8.4**.
- Every `native build` passes **`-Dtrace=off`**. `scripts/check-release-flags.sh`
  fails CI otherwise.
- `native dev` / Debug GUI link **fails on this machine** (crt1.o `.sframe`).
  Use ReleaseFast `native build -Dautomation=true -Dtrace=off` to run or verify.
- **No heap ownership in the Model.** All strings are copied into fixed
  `*_store` / `*_buf` buffers; row structs hold slices into them.
- **Every `Model` field must be bound in markup or listed in
  `Model.view_unbound`**, or the dead-state lint fails the build. This plan
  adds a field to `view_unbound` in Task 2 and removes it again in Task 4 when
  markup binds it — that sequencing is deliberate, not an oversight.
- **Design envelope** (`design-reference/claude-design-brief.md`): only the 7
  station theme tokens, no per-element hex, no shadows/blur/absolute
  positioning, no letter-spacing or text-transform (author uppercase as
  uppercase text). The widget vocabulary is closed.
- Markup `<icon name="...">` validates against the SDK's **closed built-in
  set at comptime**. App icons are registered SVGs in `src/icons/`, reached as
  `icon="app:<name>"`.
- `app.zon`'s `.close_policy` must keep the literal `.close_policy = "…"`
  shape — `scripts/set-close-policy.sh` asserts on it.
- A `/` in a scene window title crashes GTK at app_start on Linux.
- `native automate assert` regex does **not** support `|` alternation.

## Two corrections to the spec, carried into this plan

The spec was written from a reading of the design surfaces and got two names
wrong. This plan uses the verified ones:

1. The on-air predicate is **`live_now()`** (`src/model.zig:535`), not
   `on_air()`. (`on_air` exists but is an unrelated per-row schedule field at
   `src/model.zig:865`.)
2. **`bell` is NOT in the SDK's built-in icon set.** The full set is: alert,
   archive, arrow-down, arrow-right, arrow-up, check-circle, check,
   chevron-down, chevron-left, chevron-right, chevron-up, circle-dot, clock,
   copy, download, edit, ellipsis, external-link, eye, file-text, folder-open,
   folder, git-branch, git-merge, git-pull-request, info, menu, mic, missing,
   moon, music, panel-left, panel-right, pause, play, plus, refresh-cw, repeat,
   save, search, send, settings, shuffle, skip-back, skip-forward, sun,
   terminal, trash, volume, wrench, x-circle, x. So the fallback path in the
   spec is the real path: Task 4 adds `src/icons/bell.svg` and reaches it as
   `icon="app:bell"`.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `patches/native-sdk-local.patch` | Modify | Regenerated HiDPI hunks against 0.8.4 |
| `scripts/apply-sdk-patches.sh` | Modify | `patch_sdk_version` pin → 0.8.4 |
| `.github/actions/setup-native/action.yml` | Modify | `native-sdk-version` pin → 0.8.4 |
| `docs/sdk-notes.md` | Modify | "What 0.8.4 changed" section |
| `app.zon` | Modify | `"notifications"` permission |
| `src/json.zig` | Modify | `notifyTrack` on the `Settings` decoder |
| `src/model.zig` | Modify | Two fields, `shouldNotifyTrack`, persistence, the effect call, lifecycle |
| `src/icons/bell.svg` | Create | App icon for the settings row |
| `src/main.zig` | Modify | Register `bell` in the `app_icons` table |
| `src/views/player-sheets.native` | Modify | NOTIFICATIONS section + switch row |
| `CLAUDE.md`, `README.md` | Modify | Version floor, gotcha revision, feature list |

---

### Task 1: Upgrade the SDK to 0.8.4

Mechanical. No app source changes — this task's deliverable is a green
`native test` on 0.8.4 with the HiDPI patch regenerated and both version pins
moved.

**Files:**
- Modify: `patches/native-sdk-local.patch`
- Modify: `scripts/apply-sdk-patches.sh` (the `patch_sdk_version` line)
- Modify: `.github/actions/setup-native/action.yml` (the `native-sdk-version` line)
- Modify: `docs/sdk-notes.md`

**Interfaces:**
- Consumes: nothing.
- Produces: an installed `@native-sdk/cli` 0.8.4 exposing
  `Effects.showNotification(options: platform.NotificationOptions) void` and
  `platform.NotificationOptions{ title: []const u8, subtitle: []const u8 = "",
  body: []const u8 = "" }`. Tasks 2–4 depend on this being installed.

- [ ] **Step 1: Record the pre-upgrade baseline**

```bash
native test 2>&1 | tail -5
```

Write down the pass count. It should be the same number after the upgrade — a
drop means the upgrade broke something, not that the tests were flaky.

- [ ] **Step 2: Install 0.8.4**

```bash
npm i -g @native-sdk/cli@0.8.4
native --version   # expect: native 0.8.4 (...)
```

- [ ] **Step 3: Confirm the patch script refuses, as designed**

```bash
./scripts/apply-sdk-patches.sh
```

Expected: **FAIL**, with a message that the patch was generated against 0.8.0
but 0.8.4 is installed. This is the script working. A unified diff carries no
version of its own, so landing the old hunks by offset or fuzz would report
success against a tree nobody checked.

- [ ] **Step 4: Confirm the patch is still needed**

```bash
SDK=$(npm root -g)/@native-sdk/cli
grep -n "gdk_surface_get_scale\b\|gdk_surface_get_scale_factor\|gtk_widget_get_scale_factor" \
  "$SDK/src/platform/linux/gtk_host.c"
```

Expected: seven hits, all on the **integer** APIs — four
`gtk_widget_get_scale_factor` and three `gdk_surface_get_scale_factor`. Zero
hits on the fractional `gdk_surface_get_scale(`. If that is what you see,
upstream [native#156] has not shipped and the patch stays. If you instead see
`gdk_surface_get_scale(` used for the density, stop and reassess — the patch
may be droppable, which changes this task entirely.

[native#156]: https://github.com/vercel-labs/native/issues/156

- [ ] **Step 5: Regenerate the patch against a pristine 0.8.4 tree**

```bash
cd /tmp && rm -rf sdk-patch-work && mkdir sdk-patch-work && cd sdk-patch-work
npm pack @native-sdk/cli@0.8.4
tar xzf native-sdk-cli-0.8.4.tgz          # -> ./package (pristine)
cp -r package pristine && cp -r package patched
cd patched
patch -p1 --fuzz=3 < ~/Projects/subwave-desktop/patches/native-sdk-local.patch
```

If hunks reject, apply them by hand: the patch adds
`native_sdk_surface_device_scale()` / `native_sdk_widget_device_scale()`
helpers that prefer `gdk_surface_get_scale()` (GTK 4.12+, fractional) and fall
back to the integer API on older GTK, then routes all seven scale-reporting
sites through them. The draw path's exactness test compares the buffer against
`ceil(logical × scale)` with one pixel of slack and maps buffer pixels 1:1 to
device pixels when it matches.

Then regenerate, stripping the timestamp lines so the checked-in patch stays
stable across regenerations:

```bash
cd /tmp/sdk-patch-work
diff -u pristine/src/platform/linux/gtk_host.c patched/src/platform/linux/gtk_host.c \
  | sed -E '1,2s/\t.*$//' > ~/Projects/subwave-desktop/patches/native-sdk-local.patch
```

- [ ] **Step 6: Bump both version pins**

In `scripts/apply-sdk-patches.sh:13`, change `patch_sdk_version="0.8.0"` to
`patch_sdk_version="0.8.4"`. In `.github/actions/setup-native/action.yml:29`,
change the `native-sdk-version` input's `default: "0.8.0"` to
`default: "0.8.4"`.

Both, not one. Skipping the CI pin is how CI ends up installing an SDK the app
no longer builds against — exactly what happened on the 0.6.0 upgrade.

- [ ] **Step 7: Apply the patch and verify idempotence**

```bash
./scripts/apply-sdk-patches.sh   # expect: success
./scripts/apply-sdk-patches.sh   # expect: success, detects already-applied
```

- [ ] **Step 8: Run the suite**

```bash
native test
```

Expected: PASS, with the same count as the Step 1 baseline.

- [ ] **Step 9: Verify the HiDPI patch took, on the fractional display**

```bash
native build -Dautomation=true -Dtrace=off
./zig-out/bin/subwave-desktop &
native automate wait | grep -o 'gpu_scale=[0-9.]*'
```

Expected: `gpu_scale=1.6666666` (or whatever this display's true fractional
scale is), **not** `gpu_scale=2`. A `2` means the patch did not land.

Kill the app by PID when done — note that in this harness `pkill -f` kills its
own wrapper shell, so use `pgrep -x subwave-desktop` and `kill <pid>`.

- [ ] **Step 10: Document the upgrade in `docs/sdk-notes.md`**

Add a section immediately above "What 0.8.0 changed", matching the established
table format:

```markdown
## What 0.8.4 changed (upgraded 2026-08-12)

Four releases (0.8.1–0.8.4, 5–10 August). Additive across every surface this
app touches, so the upgrade forced no app edits — but unlike 0.8.0 it carries
one capability worth building on.

| Surface | 0.8.0 → 0.8.4 |
| --- | --- |
| `Effects` `pub fn` list | additions only: `showNotification`, the audio-capture verbs, three `feed*` test helpers |
| `PlatformFeature` enum, `*_fn` platform services | identical |
| `src/platform/linux/gtk_host.c` | **changed** (~80 lines) — the HiDPI patch was regenerated; see below |
| `app.zon` manifest | one new permission, `system_audio` (audio capture; unused here) |
| Markup vocabulary | additions only: `images` on `<markdown>`, `submit-on-enter`, `max_width`, `on_drag` |
| Built-in icons | `mic.svg` added |
| `minimum_zig_version` | 0.16.0, unchanged |
| Trace default | still `.events` — `-Dtrace=off` stays mandatory |

**`fx.showNotification` is the useful part**, and the app now uses it for
track-change toasts (`shouldNotifyTrack` in `src/model.zig`). It is
fire-and-forget by design: platform acceptance does not mean the OS displayed
it, since Focus / Do Not Disturb and user settings stay authoritative, so no
success `Msg` would be truthful. Bounds are title 1–128 bytes, subtitle ≤128,
body ≤1024; invalid fields, a missing service and a host refusal all fail
closed. Wired on all three platforms (`show_notification_fn` non-null in the
macOS, Windows and Linux hosts; Linux goes through
`native_sdk_gtk_show_notification` and refuses when the web engine is not
`.system`).

It is **inert and unrecorded under fake execution and session replay** — there
is no `notificationState()` to assert on, unlike `windowActionState()`. That is
why the app's decision logic lives in the pure `Model.shouldNotifyTrack()`
predicate and the effect call itself is one untested line.

**Audio capture also landed** (`startAudioCapture` / `stopAudioCapture` /
`feedAudioCapture`, the `system_audio` permission, the `mic` icon). That is
microphone input; a radio player has no use for it.

**The HiDPI patch survived and was regenerated.** `gtk_host.c` moved, but all
seven scale-reporting sites still read an integer API — four
`gtk_widget_get_scale_factor()` and three `gdk_surface_get_scale_factor()`
(the *integer* GDK entry point, not the fractional `gdk_surface_get_scale()`).
vercel-labs/native#156 is still open.

The README repositions TypeScript cores as the default scaffold (`native init`
takes `--template ts-core|zig-core`, defaulting to TS), with Zig "a first-class
app-core alternative by explicit choice". That is scaffolding and docs, not a
runtime change; a Zig app that already works is unaffected.

Still **no** OS media-controls surface (no MPRIS, MPNowPlayingInfoCenter or
SystemMediaTransportControls anywhere in the 0.8.4 tree) and still **no** audio
output-device API. Re-checked by grep, not assumed. `-Dtrace=off` re-confirmed
mandatory: `build.zig` still defaults `-Dtrace` to `.events`.
```

- [ ] **Step 11: Commit**

```bash
git add patches/native-sdk-local.patch scripts/apply-sdk-patches.sh \
        .github/actions/setup-native/action.yml docs/sdk-notes.md
git commit -m "Upgrade Native SDK 0.8.0 -> 0.8.4"
```

---

### Task 2: Model state, the pure predicate, and settings persistence

No effect call and no UI yet — this task's deliverable is the tested decision
logic and a settings key that round-trips.

**Files:**
- Modify: `src/json.zig` (the `Settings` struct, around line 250-264)
- Modify: `src/model.zig` (fields, `view_unbound`, `applySettingsJson`, `saveSettings`, tests)

**Interfaces:**
- Consumes: SDK 0.8.4 from Task 1.
- Produces:
  - `Model.notify_track: bool` (default `false`)
  - `Model.app_active: bool` (default `true`)
  - `pub fn Model.shouldNotifyTrack(self: *const Model) bool`
  - the `notifyTrack` key in settings.json
  - Task 3 calls `shouldNotifyTrack()` and writes `app_active`; Task 4 binds
    `notify_track` in markup.

- [ ] **Step 1: Write the failing tests**

Append to the test block in `src/model.zig`, alongside the existing
`"discord settings round-trip through applySettingsJson"` test:

```zig
test "shouldNotifyTrack gates on opt-in, background, on-air and a real track" {
    var m = Model{};
    setStr(&m.title_buf, &m.title, "Night Drive");
    m.transport = .playing;
    m.stream_online = true;
    m.notify_track = true;
    m.app_active = false;

    // All four gates open.
    try testing.expect(m.shouldNotifyTrack());

    // Opt-out wins over everything else.
    m.notify_track = false;
    try testing.expect(!m.shouldNotifyTrack());
    m.notify_track = true;

    // Foreground: the LIVE stage already shows the track, so no toast.
    m.app_active = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.app_active = false;

    // Tuned out: the app is a player, not a station ticker.
    m.transport = .stopped;
    try testing.expect(!m.shouldNotifyTrack());
    m.transport = .playing;

    // Mid-buffer and mid-failure are not "on air".
    m.buffering = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.buffering = false;
    m.stream_failed = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.stream_failed = false;

    // Offline stream: nothing is airing to announce.
    m.stream_online = false;
    try testing.expect(!m.shouldNotifyTrack());
    m.stream_online = true;

    // The first fill: got_np flips title from "" and sets track_changed, but
    // that is a first fill at launch, not a track change.
    m.title = "";
    try testing.expect(!m.shouldNotifyTrack());
}

test "notifyTrack round-trips through applySettingsJson" {
    var m = Model{};
    try testing.expect(!m.notify_track); // off by default: no key, no toasts

    applySettingsJson(&m, "{\"notifyTrack\":true}");
    try testing.expect(m.notify_track);

    applySettingsJson(&m, "{\"notifyTrack\":false}");
    try testing.expect(!m.notify_track);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `native test`
Expected: FAIL — `no field or member function named 'shouldNotifyTrack'` and
`no field named 'notify_track'`.

- [ ] **Step 3: Add the two Model fields**

In `src/model.zig`, next to `discord_enabled: bool = false,` (around line 374):

```zig
    // Desktop track-change toasts (SDK 0.8.4 fx.showNotification). Opt-in:
    // an existing settings.json has no notifyTrack key, so an update never
    // starts interrupting a listener who did not ask for it.
    notify_track: bool = false,
    // App foreground state, from the app_activated / app_deactivated
    // lifecycle Msgs. Only the notification gate reads it — a toast that
    // repeats what the on-screen stage already says is noise.
    app_active: bool = true,
```

- [ ] **Step 4: Add the pure predicate**

In `src/model.zig`, immediately after `pub fn live_now` (around line 537):

```zig
    /// Background-only, on-air-only, and never the first fill: the whole
    /// track-toast decision, kept pure because `fx.showNotification` is
    /// inert and unrecorded under fake execution, so no test can observe
    /// the call itself.
    pub fn shouldNotifyTrack(self: *const Model) bool {
        return self.notify_track and !self.app_active and self.live_now() and self.has_track();
    }
```

- [ ] **Step 5: Opt the new names out of the dead-state lint**

Both new fields and the new method are read by `update` only, never bound in
markup — for now. In `Model.view_unbound`, add to the discord group (around
line 1307):

```zig
        // track-change notifications (notify_track is bound by the panel
        // switch in player-sheets.native; the rest is update-only state)
        "app_active",         "shouldNotifyTrack",
```

and, **temporarily**, `"notify_track"` alongside them. Task 4 binds
`notify_track` in markup and removes it from this list again. Without the
temporary entry the build fails the dead-state lint between Task 2 and Task 4.

- [ ] **Step 6: Add the settings key to the decoder**

In `src/json.zig`, in `pub const Settings`, after `discordClientId`:

```zig
    // Desktop track-change notifications; absent = off (opt-in).
    notifyTrack: ?bool = null,
```

- [ ] **Step 7: Apply and persist the setting**

In `src/model.zig`'s `applySettingsJson`, next to the discord lines (around
line 1705):

```zig
    if (s.notifyTrack) |v| model.notify_track = v;
```

In `saveSettings` (around line 1729), extend the format string with
`,\"notifyTrack\":{s}` between `discordClientId` and `recents`, and add the
matching argument after `model.discord_client_id`:

```zig
    w.print("{{\"volume\":{d:.2},\"themeOverride\":\"{s}\",\"streamFormat\":\"{s}\",\"station\":\"{s}\",\"stationName\":\"{s}\",\"stationPassword\":\"{s}\",\"discordEnabled\":{s},\"discordClientId\":\"{s}\",\"notifyTrack\":{s},\"recents\":[", .{
        model.volume,
        jsonEscape(esc[0..64], model.theme_override),
        model.format_pref.id(),
        model.base,
        jsonEscape(esc[64..128], model.station_name),
        jsonEscape(&pw_esc, model.station_pw),
        if (model.discord_enabled) "true" else "false",
        model.discord_client_id,
        if (model.notify_track) "true" else "false",
    }) catch return;
```

`settings_json_buf` is `[3072]u8` and this adds ~22 bytes, so no resize is
needed.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `native test`
Expected: PASS, with two more tests than the Task 1 baseline.

- [ ] **Step 9: Commit**

```bash
git add src/json.zig src/model.zig
git commit -m "Add the track-notification opt-in and its decision predicate"
```

---

### Task 3: Wire the effect and the lifecycle

**Files:**
- Modify: `src/model.zig` (the `.got_np` arm around line 2294, the
  `.app_activated` / `.app_deactivated` arms around line 2997)
- Modify: `app.zon` (`.permissions`)

**Interfaces:**
- Consumes: `Model.shouldNotifyTrack()`, `Model.notify_track`,
  `Model.app_active` from Task 2.
- Produces: nothing new for later tasks — Task 4 is UI only.

- [ ] **Step 1: Declare the permission**

In `app.zon`, change:

```zon
    .permissions = .{ "view", "command" },
```

to:

```zon
    .permissions = .{ "view", "command", "notifications" },
```

Leave `.capabilities` and `.close_policy` untouched —
`scripts/set-close-policy.sh` asserts on the literal `.close_policy = "…"`
shape.

- [ ] **Step 2: Set `app_active` from the lifecycle arms**

In `src/model.zig` (around line 2997), the two arms currently read:

```zig
        .app_activated => if (model.phase == .player) fetchFeed(model, fx),
```
```zig
        .app_deactivated => model.band_levels = [_]f32{0} ** spectrum.band_count,
```

Change them to also track foreground state:

```zig
        .app_activated => {
            model.app_active = true;
            if (model.phase == .player) fetchFeed(model, fx);
        },
```
```zig
        .app_deactivated => {
            model.app_active = false;
            model.band_levels = [_]f32{0} ** spectrum.band_count;
        },
```

- [ ] **Step 3: Call the effect at the track-change site**

In the `.got_np` arm of `update`, the `track_changed` flag is computed from the
title and artist comparisons around line 2294, and `model.show` is filled later
in the same arm (around line 2360, from `np.activeShow`). Place the call
**after** the `if (np.activeShow)` block so all three fields describe the new
track rather than a mix of new and old:

```zig
            // SDK 0.8.4: a background toast is the closest this SDK gets to a
            // Now Playing surface while OS media controls stay absent. The
            // OS supplies the app name as the notification header on all
            // three platforms, so the title slot carries the track, not
            // "SUBWAVE". Fire-and-forget by design — no result Msg would be
            // truthful, since Focus / Do Not Disturb stay authoritative.
            if (track_changed and model.shouldNotifyTrack()) {
                fx.showNotification(.{
                    .title = model.title,
                    .subtitle = model.artist,
                    .body = model.show,
                });
            }
```

All three are slices into the Model's fixed buffers, whose sizes cap them well
inside the SDK's 128 / 128 / 1024 byte bounds. `model.show` is `""` when no
show is active, which is an allowed empty optional.

- [ ] **Step 4: Verify the suite still passes**

Run: `native test`
Expected: PASS, same count as Task 2. Under fake execution
`showNotification` returns before doing anything, so no existing test changes
behavior — that is the point, and why Task 2's predicate carries the coverage.

- [ ] **Step 5: Verify the manifest**

Run: `native check`
Expected: PASS — the manifest and every view validate. If `"notifications"` is
rejected as a permission name, stop: it should be accepted (the SDK's manifest
parser maps it at `src/tooling/manifest.zig`), and a rejection means the
permission spelling changed.

- [ ] **Step 6: Commit**

```bash
git add app.zon src/model.zig
git commit -m "Post a desktop toast when the track changes in the background"
```

---

### Task 4: The settings switch, the icon, and the docs

**Files:**
- Create: `src/icons/bell.svg`
- Modify: `src/main.zig` (the `app_icons` table, lines 38-53)
- Modify: `src/views/player-sheets.native` (after the SIGNAL section, around line 95)
- Modify: `src/model.zig` (remove the temporary `view_unbound` entry, add the toggle Msg)
- Modify: `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: `Model.notify_track` and the settings persistence from Task 2.
- Produces: the `toggle_notify` Msg; nothing later depends on it.

- [ ] **Step 1: Create the bell icon**

The SVG must be in the common 24×24 stroke-icon dialect that
`canvas.svg_icon.parseComptime` accepts — same shape as the existing
`src/icons/radio.svg`. Create `src/icons/bell.svg`:

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.27 21a2 2 0 0 0 3.46 0"/><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/></svg>
```

- [ ] **Step 2: Register it**

In `src/main.zig`, add the embed next to the others (alphabetical, so before
`disc_icon` at line 38):

```zig
const bell_icon = canvas.svg_icon.parseComptime(@embedFile("icons/bell.svg"));
```

and the table entry as the first element of `app_icons` (line 46):

```zig
    .{ .name = "bell", .icon = &bell_icon },
```

- [ ] **Step 3: Add the toggle Msg**

In `src/model.zig`'s `Msg` union, next to `toggle_discord`:

```zig
    toggle_notify,
```

and its arm in `update`, next to `.toggle_discord` (around line 3199):

```zig
        .toggle_notify => {
            model.notify_track = !model.notify_track;
            saveSettings(model, fx);
        },
```

- [ ] **Step 4: Add the panel row**

In `src/views/player-sheets.native`, between the SIGNAL section's stream-format
row and the `<use template="section-label" title="INTEGRATIONS"/>` line (around
line 95):

```xml
            <use template="section-label" title="NOTIFICATIONS"/>
            <row main="space_between" cross="center" padding="10" label="Track notifications">
              <row gap="10" cross="center">
                <icon name="app:bell" width="16" height="16" foreground="text_muted"/>
                <text>Track notifications</text>
              </row>
              <switch selected="{notify_track}" on-toggle="toggle_notify" label="Track notifications"/>
            </row>
```

An inline `<switch>`, not a sub-sheet like Discord Rich Presence: Discord needs
a client ID entered and validated, so it earns a sheet. This needs nothing.
Note the section title is authored as literal uppercase text — the design
envelope forbids `text-transform`.

- [ ] **Step 5: Remove the temporary lint opt-out**

`notify_track` is now bound in markup, so delete `"notify_track"` from
`Model.view_unbound` (added in Task 2, Step 5). Leave `"app_active"` and
`"shouldNotifyTrack"` — those stay update-only.

- [ ] **Step 6: Verify**

```bash
native check   # markup + manifest validate in milliseconds
native test    # src/tests.zig lays out every fragment across all branches
```

Expected: both PASS. `src/tests.zig` builds and lays out every view fragment
across all tab/sheet/phase branches, so the new row is covered as soon as it
exists. If `native check` rejects `app:bell`, the icon name in the markup and
the `app_icons` table entry disagree — they must match exactly.

If the dead-state lint now complains that `notify_track` is listed in
`view_unbound` *and* bound in markup, Step 5 was skipped.

- [ ] **Step 7: See it work**

```bash
native build -Dautomation=true -Dtrace=off
./zig-out/bin/subwave-desktop &
native automate wait && native automate screenshot main-canvas
```

Screenshot lands at
`.zig-cache/native-sdk-automation/screenshot-main-canvas.png`. Open the back
panel and confirm the NOTIFICATIONS row renders with the bell and the switch.

Then the live check: turn the switch on, click away so the app loses focus, and
wait for the station to change track (a few minutes). A toast should appear.
With the app focused, no toast — that is `!app_active` doing its job.

**Careful:** if you point the app at a dev station with `SUBWAVE_STATION_URL`,
that run **persists the test station into the real settings.json**. Back the
file up first and restore it afterwards.

- [ ] **Step 8: Update the docs**

In `CLAUDE.md`, change the SDK floor in the "What this is" paragraph from
`**0.8.0+**` to `**0.8.4+**`, and revise the media-controls gotcha:

```markdown
- SDK 0.8.4 still has **no OS media-controls surface** (no
  MPNowPlayingInfoCenter / MPRemoteCommandCenter / MPRIS / hardware media keys
  — re-checked at the 0.8.4 upgrade). The substitutes are the tray extra, the
  in-window keyboard transport, and the background track toast
  (`fx.showNotification`, opt-in via the back panel's NOTIFICATIONS row; the
  decision lives in `Model.shouldNotifyTrack`).
```

Also update the audio-device gotcha's version reference from 0.8.0 to 0.8.4 —
it was re-checked and still holds.

In `README.md`, add track notifications to the features list, noting it is
opt-in and background-only.

- [ ] **Step 9: Commit**

```bash
git add src/icons/bell.svg src/main.zig src/model.zig \
        src/views/player-sheets.native CLAUDE.md README.md
git commit -m "Add the track-notification switch to the back panel"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: the SDK upgrade,
patch regeneration and both pins → Task 1 (which also carries the
`docs/sdk-notes.md` entry, since that document *is* the upgrade's deliverable).
The manifest permission, model fields, pure predicate and call site → Tasks 2
and 3. The UI switch, icon and remaining docs → Task 4. Testing is distributed
into the tasks rather than deferred, per TDD. The spec's "out of scope" list
(audio capture, the new markup attributes, a TypeScript core, further host
patches) is not implemented anywhere, which is correct.

**Corrections found during planning.** Two spec names were wrong and are fixed
here: `on_air()` → `live_now()`, and `bell` is not a built-in icon so Task 4
takes the app-SVG path the spec listed as a fallback. Planning also surfaced a
constraint the spec missed: the dead-state lint forces `notify_track` into
`view_unbound` for the window between Task 2 and Task 4, which is now explicit
in both tasks.

**Type consistency.** `shouldNotifyTrack`, `notify_track`, `app_active`,
`toggle_notify` and `notifyTrack` are spelled identically everywhere they
appear. `live_now()` and `has_track()` are pre-existing and verified at
`src/model.zig:535` and `:700`. `NotificationOptions`' three field names match
the SDK's definition at `src/platform/types.zig:1334`.
