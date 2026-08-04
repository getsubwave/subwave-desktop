# Local SDK notes

**Quick re-apply after any SDK upgrade** (idempotent):

```bash
./scripts/apply-sdk-patches.sh
native test   # verify
```

The unified diff lives at `patches/native-sdk-local.patch`, generated against
the pristine 0.7.1 npm tarball and re-verified against 0.8.0, whose
`gtk_host.c` is byte-identical (so the hunks land with zero offset and the file
needed no regeneration). Symptom of a lost patch: pixelated text on a
fractional-scale Linux display.

## Two version pins, and they must agree

- `.github/actions/setup-native/action.yml` → `native-sdk-version`: what CI
  **installs**.
- `scripts/apply-sdk-patches.sh` → `patch_sdk_version`: what the patch was
  **generated against**. The script reads the installed package's version and
  refuses to run on anything else — a unified diff carries no version of its
  own, so `patch` would otherwise land the hunks on a different release by
  offset or fuzz and report success against a tree nobody checked.

Upgrading the SDK, in order:

```bash
npm i -g @native-sdk/cli@<new>
./scripts/apply-sdk-patches.sh          # fails: patch says 0.6.0, install says <new>
```

That failure is the prompt to do the real work: check whether the patch is
still needed at all (upstream may have fixed it — two of the three were fixed
in 0.6.0), and if it is, regenerate it against the new tarball:

```bash
npm pack @native-sdk/cli@<new> && tar xzf native-sdk-cli-<new>.tgz    # pristine tree
#   apply the old hunks to a copy, diff the two, drop the timestamp lines
#   from the +++/--- header so the checked-in patch stays stable
```

Then bump `patch_sdk_version` AND `native-sdk-version`, and run `native test`.
Skipping the second bump is how CI ends up installing an SDK the app no longer
builds against — which is exactly what happened on the 0.6.0 upgrade: the pin
stayed at 0.5.3 and all four jobs failed on `<image>`, an element that release
did not have.

## What SDK 0.6.0 took over (patches deleted 2026-07-25)

Two of the three long-standing local patches shipped upstream in 0.6.0 and are
gone from `patches/native-sdk-local.patch`. Kept here as history, because the
workarounds they replaced are still visible in the git log:

- **canonicalizeComptime quota** ([native#148]) — 0.5.x recomputed the comptime
  branch quota with a recursive `documentByteSize` scan that itself blew the
  default 1000-branch budget on a document the size of the player, so
  `CompiledMarkupView` failed to build with `ui_markup.zig:1014: evaluation
  exceeded 1000 backwards branches`. 0.6.0 carries `source_bytes` on
  `MarkupDocument` and sizes the walk in O(1). No app-side workaround remains.
- **Close-hides-window + reserved tray ids** ([native#149]) — the AppKit host
  hard-coded "last window closed → shut down", so the red close button killed
  playback; the patch added a `windowShouldClose:` that hid the app, plus tray
  item ids 100 (unhide) / 101 (quit) the runtime could not otherwise reach.
  0.6.0 replaces **both halves** with first-class API — see below.

[native#148]: https://github.com/vercel-labs/native/issues/148
[native#149]: https://github.com/vercel-labs/native/issues/149

## What 0.8.0 changed (upgraded 2026-08-04)

0.8.0 is a **TypeScript-core release**, and this app has no TypeScript core —
its logic is Zig and its views are markup. The headline change (TS cores now
compile through an external core compiler, and the TS-to-Zig transpiled lane is
removed as a deliberate pre-1.0 break) cannot reach a Zig app: the only trace of
it in our manifest surface is a new optional `core_compiler` field that defaults
to `"external"` and which `app.zon` never mentions.

The useful part of this upgrade is really **0.7.2**, which we skipped over:

| Surface | 0.7.1 → 0.8.0 |
| --- | --- |
| `Effects` `pub fn` list | identical |
| `PlatformFeature` enum, `*_fn` platform services | identical |
| `src/platform/linux/gtk_host.c` | **byte-identical** — the HiDPI patch is untouched |
| CLI `bin/` | byte-identical |
| Automation protocol | `0x096c8aa4730c11ec`, unchanged — existing `native automate` calls keep working |
| `minimum_zig_version` | 0.16.0, unchanged |
| Markup vocabulary | additions only: `added-lines` / `removed-lines` on `<code>` (Geist-style diffs) |
| `DesignTokens` | additive: `button_disabled_border` and five `tabs_*` metrics; `theme.zig` writes only color slots, so defaults apply |
| `app.zon` manifest | one new optional field, `core_compiler` (default `"external"`); everything we declare is unchanged |
| Trace default | still `.events` — see the `-Dtrace=off` section below, the flag stays mandatory |

Two 0.7.2 fixes land on platforms this app ships to, neither needing an app edit:

- **Windows GPU surfaces now render through Direct2D/DirectWrite** with
  dirty-region patching, replacing the software RGBA→BGRA path. That is the
  Windows leg of our one `gpu_surface` view, so it is worth a look on the next
  Windows release build.
- **`Effects.spawn` no longer flashes a console window** on Windows when a
  tray/GUI app launches a console-subsystem child. `links.zig` opens every
  outbound URL through a spawned per-OS browser argv, so this removes a visible
  black-box blink on Windows for free.

Still **no** audio output-device API and still no OS media-controls surface — no
MPRIS, MPNowPlayingInfoCenter or SystemMediaTransportControls anywhere in the
0.8.0 tree. Re-checked, not assumed.

## What 0.7.1 changed (upgraded 2026-08-01)

Additive across every surface this app touches, which is why the upgrade landed
with zero app edits and 75/75 tests still green:

| Surface | 0.6.0 → 0.7.1 |
| --- | --- |
| `Effects` `pub fn` list | identical |
| `PlatformFeature` enum, `*_fn` platform services | identical |
| Markup vocabulary | additions only: a `<code>` widget plus `language`, `line-numbers`, `editable`, `on-input` |
| `DesignTokens` | seven new `syntax_*` slots for that widget; `theme.zig` writes only color slots, so defaults apply |
| `app.zon` manifest | four new optional window fields (`transparent`, `always_on_top`, `click_through`, `activate_on_show`); `close_policy` unchanged |
| CLI `bin/` | byte-identical |
| `minimum_zig_version` | 0.16.0, unchanged |

Nothing removed, nothing renamed. Still **no** audio output-device API and
still no OS media-controls surface — no MPRIS, MPNowPlayingInfoCenter or
SystemMediaTransportControls anywhere in the tree.

## No audio output-device selection (checked 0.6.0, 0.7.1 and 0.8.0)

The platform seam's whole audio surface is `audio_load` / `audio_load_url` /
`play` / `pause` / `stop` / `seek` / `set_volume`. There is no device
enumeration and no output-device property, so the app cannot offer a "play
through these speakers" picker — the single player follows the system default
wherever the host puts it.

Written up as an upstream request in
[`sdk-audio-device-request.md`](sdk-audio-device-request.md), which carries the
per-platform implementation notes (GStreamer `GstDeviceMonitor`,
`AVPlayer.audioOutputDeviceUniqueID`, `IMFMediaEngineEx`). Deliberately **not**
patched locally: three more host patches to carry across every SDK upgrade is
a bad trade against one HiDPI patch, and two of the three platforms already
route per-app audio at the OS level (the README says how).

## close_policy: declared per target, not per manifest

`app.zon`'s `.shell.windows[0].close_policy` is now the menu-bar-app switch
(`"quit"`, the default, or `"hide"`), and `fx.showWindow("main")` / `fx.quitApp()`
let the model drive the tray's "Open player" and "Quit" rows itself — so the
status item is plain `on_command` → `Msg` on every platform, with no reserved
host-side ids.

The catch: `"hide"` is validated against the **build target** at comptime, and
`app.zon` has no per-platform scoping.

| target | `"hide"` | why |
| --- | --- | --- |
| macOS | always allowed | the Dock reopen path always exists |
| Windows | allowed **with the `"tray"` capability** | hiding removes the taskbar entry and there is no dock, so only the status item can bring it back |
| Linux | **compile error** | the GTK host has no status item at all, so a hidden window would be stranded |

So the checked-in manifest declares `"quit"` — the Linux-safe default, and what
every local `native test` / `native build` on this repo's Linux dev box uses —
and `scripts/set-close-policy.sh hide` flips it for the macOS and Windows legs
of CI and both release workflows. That script fails loudly if `app.zon` ever
drifts out from under it, so the flip can't silently become a no-op and ship the
wrong close behavior. `"tray"` is declared in `.capabilities` unconditionally:
it is what the app actually installs, and Windows requires it before accepting
`"hide"`.

## Fractional HiDPI scale patch (Linux text rendering) — STILL NEEDED

On a fractional-scale Linux desktop (Wayland `wp_fractional_scale_v1` — e.g. a
4K panel at 1.6667 / "167%") all text rendered blurry and pixelated, while
macOS and Windows were fine. The GTK host derives the surface density from
`gtk_widget_get_scale_factor()`, which is an **integer** API and rounds up:

```
gtk_widget_get_scale_factor(drawarea) = 2        <-- what gtk_host.c uses
gdk_surface_get_scale(surface)        = 1.6667   <-- the true scale
```

So the runtime rasterizes the canvas at logical × 2 (2266x2492) for a surface
that is only 1888x2076, and the surplus has to be resampled away at present
time. Worse, the filter choice in `native_sdk_gpu_surface_draw` compares the
buffer's density against that *same* integer, concludes "exact, steady state"
and picks `CAIRO_FILTER_NEAREST` — so a genuinely fractional 2266→1888
downscale runs through nearest-neighbour, dropping ~1 pixel column in 6 instead
of averaging. Hard-edged UI survives that; glyph antialiasing does not, which is
why only *text* looks broken. The other hosts read fractional densities
(`backingScaleFactor` on macOS, `GetDpiForWindow()/96.0` on Windows), hence
Linux-only.

Patched locally in `src/platform/linux/gtk_host.c` by adding
`native_sdk_surface_device_scale()` / `native_sdk_widget_device_scale()`
helpers that prefer `gdk_surface_get_scale()` (GTK 4.12+, fractional) and fall
back to the integer API on older GTK, then routing all seven scale-reporting
sites through them. The draw path's exactness test compares the buffer against
`ceil(logical × scale)` with one-pixel slack (the runtime ceils, so a 1133-wide
surface at 1.6667 yields an 1889px buffer for 1888px of screen) and maps buffer
pixels 1:1 to device pixels when it matches, letting the surplus edge column
fall outside the clip.

0.6.0, 0.7.1 and 0.8.0 all still read the integer API at every one of those
sites (0.6.0 added `gdk_surface_get_scale_factor` calls, which is the *integer*
GDK entry point, not the fractional `gdk_surface_get_scale`; 0.7.1 changed none
of them, and 0.8.0 does not touch `gtk_host.c` at all), so the patch still
applies — with zero fuzz. **Re-apply after every
`npm i -g @native-sdk/cli` upgrade**, or drop it once
[vercel-labs/native#156](https://github.com/vercel-labs/native/issues/156)
ships — still open as of 0.8.0. Integer scales (100%/200%) are unaffected, which is why it can look fine
on a second machine.

Verify it took on a fractional display: run the app under automation and read
the surface density back —

```bash
native automate wait | grep -o 'gpu_scale=[0-9.]*'   # 1.6666666, not 2
```

## `-Dtrace=off` is mandatory on shipping builds

Not a patch — a build flag, but just as load bearing as the local
`gtk_host.c` patch above. The SDK's default trace mode writes a record per
frame and per audio callback, each one a full open/stat/write/close on an
unbounded file, inline on the message loop thread. On Windows behind an AV
minifilter that stalls the pump outright (issue #23).

Every `native build` in every workflow passes `-Dtrace=off`, and
`scripts/check-release-flags.sh` fails CI if one does not. Panic capture is
outside the trace gate, so `last-panic.txt` still works.

Re-check this at every SDK upgrade: if `FileTraceSink` starts holding its
handle open, or per-frame events leave the default level, the flag can go.
The upstream request is `docs/sdk-trace-log-request.md`. Re-checked at 0.8.0:
`src/primitives/trace/` is byte-identical to 0.7.1 and `build.zig` still
defaults `-Dtrace` to `.events`, so the flag stays mandatory.

