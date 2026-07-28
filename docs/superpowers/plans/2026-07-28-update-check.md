# Update Check + Notify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app polls GitHub Releases daily, shows a quiet "update available" notice in the BACK PANEL sheet (plus an accent dot in the top bar), and opens the release page in the default browser on click.

**Architecture:** A new pure module `src/update.zig` owns the compiled-in version, the GitHub URLs, the strict `vX.Y.Z` compare, and the per-OS opener argv. `model.zig` wires one fetch key, one daily timer, and three Msgs through the existing Elm-style reducer; the notice state is a single tag string in a fixed Model buffer. Views bind `{update_available}` / `{update_value}` / `{app_version}`.

**Tech Stack:** Zig 0.16, Vercel Native SDK 0.6.0 effects channel (`fetch`, `startTimer`, `spawn`), `.native` markup. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-28-update-check-design.md`

## Global Constraints

- Zig 0.16.0; SDK `@native-sdk/cli` 0.6.0+ with the local HiDPI patch — do not touch SDK code.
- Design envelope: only the 7 station tokens, fixed type scale, closed icon set (`download` and `circle-dot` are built-ins — allowed).
- All Model strings live in fixed buffers on the Model (`setStr`); no heap ownership.
- Test gate: `native test` (unit tests + markup build/layout contract) must pass at every commit.
- On this machine use `native build -Dautomation=true` (ReleaseFast) for any run/smoke check — `native dev` debug links fail (crt1.o .sframe).
- Effect keys share one keyspace; new keys must not collide (43/44/45 are free; `cover_image_base` starts at 1000).

---

### Task 1: `src/update.zig` pure module

**Files:**
- Create: `src/update.zig`
- Modify: `src/tests.zig:10-15` (test discovery import list)

**Interfaces:**
- Produces: `pub const version: []const u8` (`"0.5.0"`), `pub const release_api_url`, `pub const release_page_url`, `pub fn isNewer(tag: []const u8) bool`, `pub const opener_argv: []const []const u8`. Task 2 imports this as `const updater = @import("update.zig");`.

- [ ] **Step 1: Write the module with inline tests**

```zig
//! Self-update phase 1: version compare + GitHub release endpoints.
//!
//! `version` is the compiled-in app version. app.zon cannot be imported from
//! src/ (outside the module path), so this constant is the runtime authority;
//! scripts/make-release.sh refuses to cut a release when the two drift.
const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.5.0";

pub const release_api_url = "https://api.github.com/repos/getsubwave/subwave-desktop/releases/latest";
pub const release_page_url = "https://github.com/getsubwave/subwave-desktop/releases/latest";

/// Default-browser opener, comptime-resolved per OS. The URL is baked in:
/// the static releases/latest page always shows the newest build, so the
/// Model never stores a per-release URL.
pub const opener_argv: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "open", release_page_url },
    .windows => &.{ "cmd", "/C", "start", "", release_page_url },
    else => &.{ "xdg-open", release_page_url },
};

const Semver = struct { major: u32, minor: u32, patch: u32 };

// Strict vMAJOR.MINOR.PATCH: optional leading v/V, exactly three numeric
// components. Anything else (prerelease suffixes included) parses to null —
// an unparseable remote tag must never arm the update notice.
fn parseTag(tag: []const u8) ?Semver {
    var s = tag;
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    var it = std.mem.splitScalar(u8, s, '.');
    const a = it.next() orelse return null;
    const b = it.next() orelse return null;
    const c = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{
        .major = std.fmt.parseInt(u32, a, 10) catch return null,
        .minor = std.fmt.parseInt(u32, b, 10) catch return null,
        .patch = std.fmt.parseInt(u32, c, 10) catch return null,
    };
}

pub fn isNewer(tag: []const u8) bool {
    const remote = parseTag(tag) orelse return false;
    const cur = parseTag(version) orelse return false;
    if (remote.major != cur.major) return remote.major > cur.major;
    if (remote.minor != cur.minor) return remote.minor > cur.minor;
    return remote.patch > cur.patch;
}

const testing = std.testing;

test "isNewer: newer on any component, with or without the v" {
    try testing.expect(isNewer("v99.0.0"));
    try testing.expect(isNewer("99.0.0"));
    try testing.expect(isNewer("v0.99.0"));
    try testing.expect(isNewer("v0.5.1"));
}

test "isNewer: equal and older stay quiet" {
    try testing.expect(!isNewer("v0.5.0"));
    try testing.expect(!isNewer("v0.4.9"));
    try testing.expect(!isNewer("v0.0.1"));
}

test "isNewer: junk and prerelease tags never arm" {
    try testing.expect(!isNewer(""));
    try testing.expect(!isNewer("v"));
    try testing.expect(!isNewer("banana"));
    try testing.expect(!isNewer("v99.0"));
    try testing.expect(!isNewer("v99.0.0.0"));
    try testing.expect(!isNewer("v99.0.0-rc1"));
}

test "version constant parses" {
    try testing.expect(parseTag(version) != null);
}
```

- [ ] **Step 2: Register in test discovery**

In `src/tests.zig`, the top-of-file test block lists the pure modules. Add one line next to `_ = @import("api.zig");`:

```zig
    _ = @import("update.zig");
```

- [ ] **Step 3: Run the suite**

Run: `native test`
Expected: PASS (new module's four tests included).

- [ ] **Step 4: Commit**

```bash
git add src/update.zig src/tests.zig
git commit -m "Add update.zig: version constant, release URLs, strict semver compare"
```

---

### Task 2: Model plumbing + reducer tests

**Files:**
- Modify: `src/json.zig` (add `Release` struct next to the other payload structs)
- Modify: `src/model.zig` — keys block (~line 50), Model fields (~line 187 near `title_buf`), view helpers (near `req_idle`, ~line 861), Msg union (~line 1181) + `view_unbound` (~line 1288), `boot` (~line 1880), reducer arms (after the `.tick_theme` arm, ~line 1905), fetch helpers (near `fetchThemes`, ~line 1433), tests at file bottom
- Test: reducer tests in `src/model.zig`

**Interfaces:**
- Consumes: `updater.version`, `updater.release_api_url`, `updater.isNewer`, `updater.opener_argv` from Task 1; existing `setStr`, `json.parse`, `Effects` helpers.
- Produces: Model bindings `update_available() bool`, `update_value() []const u8`, `app_version() []const u8`; Msg `.open_release` (markup-bound). Task 3's markup uses exactly these names.

- [ ] **Step 1: Add the JSON payload struct**

In `src/json.zig`, next to the other payload structs:

```zig
pub const Release = struct {
    tag_name: ?[]const u8 = null,
};
```

- [ ] **Step 2: Import + keys + fields + helpers in model.zig**

Top of `model.zig`, with the other file imports (NOTE the alias — `update` is the reducer's name):

```zig
const updater = @import("update.zig");
```

In `pub const keys`, after `discord_retry`:

```zig
    pub const fetch_update: u64 = 43;
    pub const update_timer: u64 = 44;
    pub const open_release_spawn: u64 = 45;
```

In the Model struct, next to the other `*_buf` fields:

```zig
    // Self-update notice: empty tag = no newer release known.
    update_tag_buf: [24]u8 = undefined,
    update_tag: []const u8 = "",
    opener_inflight: bool = false,
```

With the other view helpers (near `req_idle`):

```zig
    // ------------------------------------------------------------ update notice
    pub fn update_available(self: *const Model) bool {
        return self.update_tag.len > 0;
    }
    pub fn update_value(self: *const Model) []const u8 {
        return self.update_tag;
    }
    pub fn app_version(self: *const Model) []const u8 {
        _ = self;
        return updater.version;
    }
```

- [ ] **Step 3: Msgs + view_unbound**

In the Msg union's effect-results section:

```zig
    got_update: native_sdk.EffectResponse,
    tick_update: native_sdk.EffectTimer,
    opener_exited: native_sdk.EffectExit,
```

In the navigation section (markup-bound, so NOT in view_unbound):

```zig
    open_release,
```

Append to `view_unbound`:

```zig
    "got_update", "tick_update", "opener_exited",
```

- [ ] **Step 4: Fetch helper + boot + reducer arms**

Near `fetchThemes`:

```zig
// Daily GitHub release poll. GitHub's API rejects UA-less requests and the
// SDK sets no default User-Agent, so both headers are explicit. Every
// failure mode (offline, rate-limited, truncated, junk) is silent — the
// next tick retries.
fn checkForUpdate(fx: *Effects) void {
    fx.fetch(.{
        .key = keys.fetch_update,
        .url = updater.release_api_url,
        .headers = &.{
            .{ .name = "User-Agent", .value = "SUBWAVE-Player" },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
    },
        .timeout_ms = 10_000,
        .on_response = Effects.responseMsg(.got_update),
    });
}
```

At the top of `boot` (before the phase branch — the check is station-independent and must run for onboarding users too):

```zig
    checkForUpdate(fx);
    fx.startTimer(.{ .key = keys.update_timer, .interval_ms = 86_400_000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_update) });
```

Reducer arms, after the `.tick_theme` arm:

```zig
        .tick_update => |t| {
            if (t.outcome == .fired) checkForUpdate(fx);
        },
        .got_update => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.Release, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            if (parsed.value.tag_name) |tag| {
                if (updater.isNewer(tag)) setStr(&model.update_tag_buf, &model.update_tag, tag) else model.update_tag = "";
            }
        },
        .open_release => {
            if (model.opener_inflight) return;
            model.opener_inflight = true;
            fx.spawn(.{
                .key = keys.open_release_spawn,
                .argv = updater.opener_argv,
                .on_exit = Effects.exitMsg(.opener_exited),
            });
        },
        .opener_exited => model.opener_inflight = false,
```

- [ ] **Step 5: Reducer tests**

At the bottom of `model.zig`, following the existing fake-executor pattern:

```zig
test "update check: newer tag arms the notice, older or garbage clears/keeps state" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // Newer release arms.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v99.0.0\"}" } }, &fx);
    try testing.expectEqualStrings("v99.0.0", m.update_tag);
    try testing.expect(m.update_available());
    // Older (or equal) release disarms — covers a rollback of a bad release.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v0.0.1\"}" } }, &fx);
    try testing.expect(!m.update_available());
    // Failures leave the armed state untouched.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v99.0.0\"}" } }, &fx);
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .timed_out, .status = 0, .body = "" } }, &fx);
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 403, .body = "rate limited" } }, &fx);
    try testing.expect(m.update_available());
}

test "open_release spawns the opener once until it exits" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .open_release, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try testing.expect(m.opener_inflight);
    // Second click while the opener lives: no second spawn.
    update(&m, .open_release, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    // Exit clears the guard.
    update(&m, .{ .opener_exited = .{ .key = keys.open_release_spawn, .reason = .exited } }, &fx);
    try testing.expect(!m.opener_inflight);
}
```

- [ ] **Step 6: Run the suite**

Run: `native test`
Expected: PASS. If `.timed_out` is not a member of the fetch outcome enum, check `EffectFetchOutcome` in the SDK's `runtime/effects.zig` and use any non-`.ok` member.

- [ ] **Step 7: Commit**

```bash
git add src/json.zig src/model.zig
git commit -m "Poll GitHub releases daily and track an update-available tag on the Model"
```

---

### Task 3: Views + layout tests

**Files:**
- Modify: `src/views/player-sheets.native:67` (SERVICE section before SHORTCUTS), `:79` (footer line)
- Modify: `src/views/player-top.native:21` (accent dot by the settings button)
- Test: `src/tests.zig` (~line 140, after the format-sheet branch)

**Interfaces:**
- Consumes: `{update_available}`, `{update_value}`, `{app_version}`, `open_release` from Task 2.

- [ ] **Step 1: BACK PANEL row**

In `player-sheets.native`, between the INTEGRATIONS row (ends line 66) and `<use template="section-label" title="SHORTCUTS"/>`:

```xml
        <if test="{update_available}">
          <use template="section-label" title="SERVICE"/>
          <row on-press="open_release" main="space_between" cross="center" padding="10" label="Update available">
            <row gap="10" cross="center">
              <icon name="download" width="16" height="16" foreground="accent"/>
              <text>Update available</text>
            </row>
            <row gap="6" cross="center">
              <text size="sm" foreground="accent">{update_value}</text>
              <icon name="chevron-right" width="14" height="14" foreground="text_muted"/>
            </row>
          </row>
        </if>
```

- [ ] **Step 2: Footer version**

Replace the footer line:

```xml
        <text size="sm" foreground="text_muted" text-alignment="center">MODEL SW-D1 · V{app_version} · MADE FOR THE INTERNET</text>
```

- [ ] **Step 3: Top-bar dot**

In `player-top.native`, immediately before the settings button (line 21):

```xml
    <if test="{update_available}">
      <icon name="circle-dot" width="10" height="10" foreground="accent"/>
    </if>
```

- [ ] **Step 4: Layout-contract coverage**

In `src/tests.zig`, after the format-sheet branch (~line 140), mirroring the arena pattern:

```zig
    // Update notice: panel row + top-bar dot with a known newer tag.
    model.update_tag = "v9.9.9";
    model.sheet = .panel;
    {
        var arena7 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena7.deinit();
        try buildAndLayout(arena7.allocator(), player_sheets_markup, &model, 980, 660);
    }
    {
        var arena8 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena8.deinit();
        try buildAndLayout(arena8.allocator(), player_top_markup, &model, 980, 660);
    }
    model.update_tag = "";
```

- [ ] **Step 5: Run the suite**

Run: `native test`
Expected: PASS — a Model-field typo in markup is a compile error here, which is the point of the contract test.

- [ ] **Step 6: Commit**

```bash
git add src/views/player-sheets.native src/views/player-top.native src/tests.zig
git commit -m "Surface the update notice: panel SERVICE row, footer version, top-bar dot"
```

---

### Task 4: Release preflight + docs

**Files:**
- Modify: `scripts/make-release.sh` (preflight, right after the `working tree clean` check ~line 60)
- Modify: `CLAUDE.md` (pure support modules list)
- Modify: `README.md` (Features list)

- [ ] **Step 1: Preflight assert**

After the `ok "working tree clean"` line:

```bash
src_version="$(sed -n 's/.*pub const version = "\([^"]*\)".*/\1/p' src/update.zig | head -1)"
[ "$src_version" = "$version" ] || fail "src/update.zig says $src_version but app.zon says $version — keep them in lockstep"
ok "src/update.zig version matches app.zon"
```

- [ ] **Step 2: CLAUDE.md**

In the pure-modules bullet of the Architecture section, add to the list:

```
`update.zig` (compiled-in version + GitHub release-check endpoints + strict semver compare; make-release.sh asserts its version matches app.zon)
```

- [ ] **Step 3: README**

Add a Features bullet:

```markdown
- **Update notice** — a daily GitHub Releases poll; a newer version lights a
  SERVICE row in the back panel (and a dot by the settings button) that opens
  the release page in the browser. No auto-install.
```

- [ ] **Step 4: Verify the preflight actually trips**

Run: `bash -c 'cd "$(git rev-parse --show-toplevel)" && sed -n "s/.*pub const version = \"\([^\"]*\)\".*/\1/p" src/update.zig'`
Expected: `0.5.0` — matches `app.zon`. (The full script needs main + gh auth; asserting the extraction is the testable slice.)

- [ ] **Step 5: Commit**

```bash
git add scripts/make-release.sh CLAUDE.md README.md
git commit -m "Assert app.zon/update.zig version lockstep at release preflight; document the update notice"
```

---

### Task 5: Full verification + ship

- [ ] **Step 1: Full suite + release build**

Run: `native test && native build -Dautomation=true`
Expected: both PASS/succeed.

- [ ] **Step 2: Headless smoke**

```bash
./zig-out/bin/subwave-desktop & sleep 2
native automate wait && native automate screenshot main-canvas
```

Expected: screenshot renders; the update row is absent (latest published release v0.4.0 is older than 0.5.0 — correct quiet state). Kill the app by PID afterwards (never `pkill -f`).

- [ ] **Step 3: Push + draft PR**

```bash
git push -u origin worktree-self-update-check
gh pr create --draft --title "Add an in-app update notice (self-update phase 1)" --body "..."
```
