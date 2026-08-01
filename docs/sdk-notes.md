# Local SDK notes

**There are no local SDK patches.** A stock `npm i -g @native-sdk/cli` is the
whole toolchain — 0.7.1 took the last one upstream. `patches/` and
`scripts/apply-sdk-patches.sh` are gone; nothing needs re-applying after an
upgrade.

One version pin remains, in `.github/actions/setup-native/action.yml` →
`native-sdk-version`: what CI **installs**. Keep it level with what the
maintainers run locally. Skipping that bump is how CI ends up installing an SDK
the app no longer builds against — exactly what happened on the 0.6.0 upgrade,
when the pin stayed at 0.5.3 and all four jobs failed on `<image>`, an element
that release did not have.

Upgrading, in full:

```bash
npm i -g @native-sdk/cli@<new>
native test                       # markup + layout contract against the new SDK
# bump native-sdk-version in .github/actions/setup-native/action.yml
```

## If a patch ever comes back

The three patches this repo used to carry are all upstream now, but the shape of
the workaround is worth keeping, because the failure mode is nasty: a unified
diff carries no version of its own, so `patch` will happily land hunks on a
different release by offset or fuzz and report success against a tree nobody
checked. Any future patch needs the same two things the deleted script had — a
`patch_sdk_version` recorded next to the diff, and a hard refusal to apply it to
any other installed version — plus a second pin bump in the CI action so the two
never drift.

## What upstream took over

### SDK 0.6.0 (patches deleted 2026-07-25)

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

### SDK 0.7.1 (patch deleted 2026-08-01)

- **Fractional HiDPI scale on the GTK host** ([native#156]) — shipped upstream
  verbatim, helpers and all. Detail below, kept because the symptom is so
  unintuitive that recognising it again is worth more than the diff was.

[native#148]: https://github.com/vercel-labs/native/issues/148
[native#149]: https://github.com/vercel-labs/native/issues/149
[native#156]: https://github.com/vercel-labs/native/issues/156

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

## Fractional HiDPI scale (Linux text rendering) — fixed upstream in 0.7.1

Kept as a diagnosis aid: if text ever goes blurry on a fractional-scale Linux
desktop again, this is the shape of it.

On Wayland `wp_fractional_scale_v1` — e.g. a 4K panel at 1.6667 / "167%" — all
text rendered blurry and pixelated while macOS and Windows were fine. The GTK
host derived the surface density from `gtk_widget_get_scale_factor()`, an
**integer** API that rounds up:

```
gtk_widget_get_scale_factor(drawarea) = 2        <-- what gtk_host.c used
gdk_surface_get_scale(surface)        = 1.6667   <-- the true scale
```

So the runtime rasterized the canvas at logical × 2 (2266x2492) for a surface
only 1888x2076, and the surplus had to be resampled away at present time. Worse,
the filter choice in `native_sdk_gpu_surface_draw` compared the buffer's density
against that *same* integer, concluded "exact, steady state" and picked
`CAIRO_FILTER_NEAREST` — so a genuinely fractional 2266→1888 downscale ran
through nearest-neighbour, dropping ~1 pixel column in 6 instead of averaging.
Hard-edged UI survives that; glyph antialiasing does not, which is why only
*text* looked broken. The other hosts read fractional densities
(`backingScaleFactor` on macOS, `GetDpiForWindow()/96.0` on Windows), hence
Linux-only. Integer scales (100%/200%) are unaffected, which is why it could
look fine on a second machine.

0.7.1 carries the fix: `native_sdk_surface_device_scale()` /
`native_sdk_widget_device_scale()` prefer `gdk_surface_get_scale()` (GTK 4.12+)
and fall back to the integer API on older GTK, with all ten scale-reporting
sites routed through them. The draw path's exactness test compares the buffer
against `ceil(logical × scale)` with one-pixel slack (the runtime ceils, so a
1133-wide surface at 1.6667 yields an 1889px buffer for 1888px of screen) and
maps buffer pixels 1:1 to device pixels when it matches, letting the surplus
edge column fall outside the clip.

Verify on a fractional display: run the app under automation and read the
surface density back —

```bash
native automate wait | grep -o 'gpu_scale=[0-9.]*'   # 1.6666666, not 2
```
