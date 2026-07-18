# Local SDK notes

**Quick re-apply after any SDK upgrade** (both patches below, idempotent):

```bash
./scripts/apply-sdk-patches.sh
native test   # verify
```

The unified diff lives at `patches/native-sdk-local.patch` (generated against
the pristine 0.5.3 npm tarball; if a future SDK version shifts the context
lines, regenerate it from the sections below). Reported upstream — drop each
patch once its fix ships: quota bug in
[vercel-labs/native#148](https://github.com/vercel-labs/native/issues/148),
close-policy + tray commands in
[vercel-labs/native#149](https://github.com/vercel-labs/native/issues/149). Symptoms of lost patches:
`native build` fails at ui_markup.zig ~line 1014, and/or the red close
button quits the app.

## canonicalizeComptime quota patch (REQUIRED for player.native)

`@native-sdk/cli` 0.5.2 has a comptime bug that breaks `CompiledMarkupView`
for large markup documents: `canonicalizeComptime` in
`src/primitives/canvas/ui_markup.zig` computes its `@setEvalBranchQuota`
argument with a recursive `documentByteSize` scan — and for a document the
size of `src/views/player.native` that scan itself exceeds the default
1000-branch budget before the quota can be raised. The error looks like:

```
ui_markup.zig:1014:58: error: evaluation exceeded 1000 backwards branches
```

The fix (applied locally to the installed package on 2026-07-17) is one line
before the existing quota call:

```zig
pub fn canonicalizeComptime(comptime document: MarkupDocument) MarkupDocument {
    comptime {
        // Raise the quota BEFORE computing the scaled quota: the byte-size
        // scan below is itself recursive, and a large document exceeds the
        // default 1000-branch budget while measuring itself.
        @setEvalBranchQuota(1_000_000);
        @setEvalBranchQuota(comptime_parse_quota_base +
            (documentByteSize(document) + 1) * comptime_canonicalize_quota_per_byte);
        ...
```

**Re-apply after every `npm i -g @native-sdk/cli` upgrade** (or drop it once
the fix ships upstream — worth reporting). File:
`$(npm root -g)/@native-sdk/cli/src/primitives/canvas/ui_markup.zig`.

App-side quota bumps (comptime blocks touching `Player.document`) do NOT
work around it — the decl gets a fresh default-quota evaluation unit
regardless of the caller's quota.

## Menu-bar-app close semantics patch (main window hides, app keeps playing)

The AppKit host hard-codes "last window closed → emitShutdown + stop"
(`windowWillClose` in `src/platform/macos/appkit_host.m`), so the red close
button killed playback. Patched locally on 2026-07-18 by adding a
`windowShouldClose:` to `NativeSdkWindowDelegate` (just above
`windowWillClose:`): while a status item is installed, closing the window
labeled `"main"` calls `[NSApp hide:nil]` and returns NO — playback and the
tray stay alive, a Dock-icon click unhides the window, and Cmd+Q / SIGTERM /
AppleScript quit still terminate normally. Model-declared windows (the mini
player) keep their real close + `on_close` dispatch.

**Re-apply after every `npm i -g @native-sdk/cli` upgrade**, same as the
quota patch. Symptom of a lost patch: closing the player window quits the
app. Worth requesting upstream as a proper option (e.g.
`ShellWindow.close_policy = "hide"`).

## Reserved tray item ids (Open player / Quit)

Same file (`appkit_host.m`, `trayMenuItemClicked:`): tray item id **100**
unhides + activates the app before forwarding (the tray's "Open player" row —
pairs with the close-hides patch), and id **101** calls `[NSApp terminate:]`
(the "Quit SUB/WAVE" row). The runtime's update loop cannot perform either.
The app assigns these ids in `main.zig`'s `statusItem`. Covered by the same
patch file / apply script. Symptom of a lost patch: those two tray rows
dispatch their (unmapped) commands and do nothing.
