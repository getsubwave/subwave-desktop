# Diagnostics and Windows Smoke Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the SDK's per-frame trace log from blocking the Windows message loop (issue #23), replace it with a bounded breadcrumb log the app owns, and make CI able to catch this class of failure.

**Architecture:** Three independent changes. Shipping builds gain `-Dtrace=off`, which disables the SDK's open/stat/write/close-per-frame trace sink while leaving panic capture intact. A new `src/diag.zig` holds one file handle open for the process lifetime and writes bounded, low-rate breadcrumbs, deliberately bypassing the effects channel because a stalled loop cannot run effects. The Windows smoke test gets pointed at a dead station so it reaches the player phase, then asserts the surface actually presented via `automate snapshot`'s `gpu_nonblank` field.

**Tech Stack:** Zig 0.16.0, `@native-sdk/cli` 0.7.1, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-03-diagnostics-and-windows-smoke-test-design.md`

## Global Constraints

- Zig 0.16.0. `native build`, `native test`, `native check` are the only build entry points.
- **Never log per-frame or per-audio-event.** That is the bug being fixed. The heartbeat is driven by elapsed time via the existing `tick_second` timer, not by frame or event count.
- No heap ownership in the Model. All strings copied into fixed `*_store` / `*_buf` buffers.
- `diag` writes synchronously and does **not** route through `fx`. This is a deliberate exemption from CLAUDE.md's effects-channel rule, for the diagnostic channel only. It must be documented in the module header.
- `diag` must be a no-op when never opened, so `native test` (which calls `update()` directly with no `main()`) writes nothing.
- Design constraints for any UI: only the 7 station theme tokens, fixed type scale, no shadows/blur/absolute positioning, icons from the closed set or `app:<name>`.
- `native automate assert` regex does **not** support `|` alternation.
- No `/` in any `app.zon` or `shell_windows` title (crashes GTK at app_start).
- Keep the `.close_policy = "…"` shape in `app.zon` — `scripts/set-close-policy.sh` asserts on it.

---

### Task 1: Ship with `-Dtrace=off`, guard it, and document why

This is the fix for #23 on its own. Everything after this task is about not regressing and not being blind next time.

**Files:**
- Modify: `.github/workflows/release-windows.yml:83` and `:124`
- Modify: `.github/workflows/release-macos.yml:95`
- Modify: `.github/workflows/release-linux.yml:92`
- Modify: `.github/workflows/ci.yml:84`
- Create: `scripts/check-release-flags.sh`
- Modify: `.github/workflows/ci.yml` (add a step running the guard)
- Create: `docs/sdk-trace-log-request.md`
- Modify: `docs/sdk-notes.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. `scripts/check-release-flags.sh` is a standalone guard invoked by CI.

- [ ] **Step 1: Write the failing guard script**

Create `scripts/check-release-flags.sh`:

```bash
#!/usr/bin/env bash
# Every shipping build MUST pass -Dtrace=off.
#
# The SDK's default -Dtrace=events writes one runtime.event record per
# rendered frame and per audio callback, and debug.appendFile does a full
# open/stat/write/close for each one — inline on the platform message loop
# thread (windowsCallback -> RunState.emit -> handler, all synchronous).
# On Windows behind an AV minifilter that scans on open and close, against a
# log file that grows without bound, this stalls the message pump: no
# WM_PAINT, a white client area, and a busy cursor on minimize/resize, at
# near-zero CPU. That is issue #23.
#
# This guard exists because the flag lives in YAML that nothing else tests.
# Drop it and the bug ships again silently.
set -euo pipefail

fail=0
for wf in release-windows release-macos release-linux ci; do
  file=".github/workflows/${wf}.yml"
  while IFS= read -r line; do
    case "$line" in
      *"-Dtrace=off"*) ;;
      *) echo "error: ${file}: 'native build' without -Dtrace=off:${line}" >&2; fail=1 ;;
    esac
  done < <(grep -n 'native build' "$file")
done

if [ "$fail" -ne 0 ]; then
  echo "error: see docs/sdk-trace-log-request.md and issue #23" >&2
  exit 1
fi
echo "ok: every 'native build' passes -Dtrace=off"
```

Make it executable:

```bash
chmod +x scripts/check-release-flags.sh
```

- [ ] **Step 2: Run the guard to verify it fails**

Run: `./scripts/check-release-flags.sh`
Expected: FAIL, exit 1, listing five `native build` lines across the four workflows (two in release-windows.yml, one each in the other three).

- [ ] **Step 3: Add the flag to all five build invocations**

In `.github/workflows/release-windows.yml`, the shipped build (currently line 83) becomes:

```yaml
        run: |
          native build -Dcpu=baseline -Dtrace=off
```

and the automation smoke build (currently line 124) becomes:

```yaml
          native build -Dautomation=true -Dcpu=baseline -Dtrace=off
```

In `.github/workflows/release-macos.yml` (currently line 95):

```yaml
        run: |
          native build -Dcpu=baseline -Dtrace=off
          native package --target macos --signing adhoc
```

In `.github/workflows/release-linux.yml` (currently line 92):

```yaml
        run: |
          native build -Dcpu=baseline -Dtrace=off
          native package --target linux
```

In `.github/workflows/ci.yml` (currently line 84):

```yaml
        run: native build -Dcpu=baseline -Dtrace=off
```

Extend each step's existing comment block with a `-Dtrace=off` paragraph, in the same register as the `-Dcpu=baseline` notes already there. For `release-windows.yml`'s "Build and package" step, append to the existing comment:

```yaml
        # -Dtrace=off is equally load bearing. The SDK's default trace mode
        # writes a record per rendered frame and per audio callback, and each
        # record is a full open/stat/write/close on an unbounded log file —
        # inline on the message loop thread. Behind Bitdefender's minifilter
        # that stalls the pump: white client area, busy cursor, near-zero CPU.
        # That is issue #23. scripts/check-release-flags.sh guards this line.
```

Use a one-or-two-sentence version of the same note in the other three files, each pointing at `scripts/check-release-flags.sh` and issue #23.

- [ ] **Step 4: Run the guard to verify it passes**

Run: `./scripts/check-release-flags.sh`
Expected: PASS, prints `ok: every 'native build' passes -Dtrace=off`

- [ ] **Step 5: Wire the guard into CI**

In `.github/workflows/ci.yml`, immediately before the `Check markup and manifest` step, add:

```yaml
      - name: Check release build flags
        # Guards -Dtrace=off across every workflow's `native build`. See
        # scripts/check-release-flags.sh and issue #23.
        if: runner.os == 'Linux'
        run: ./scripts/check-release-flags.sh
```

The `if` keeps it to one runner — it reads repo files, not build output, so running it three times adds nothing.

- [ ] **Step 6: Verify the build still compiles with the flag**

Run: `native build -Dcpu=baseline -Dtrace=off`
Expected: exit 0, no output.

Then confirm panic capture survives the flag by reading `debug/root.zig:115-122` and `:197-214`: `installPanicCapture` is called unconditionally in `app_runner/root.zig:488`, and `capturePanic` writes `last-panic.txt` and its own trace record directly rather than through the filtered sink. No code change needed; this step is a read-and-confirm so the next person does not have to re-derive it.

- [ ] **Step 7: Write the upstream request**

Create `docs/sdk-trace-log-request.md`, following the shape of `docs/sdk-audio-device-request.md`:

```markdown
# SDK request: the file trace sink blocks the message loop

## What happens

`runWithOptions` wires `debug.FileTraceSink` unconditionally
(`app_runner/root.zig:487-500`). With the default `-Dtrace=events`
(`build/app.zig:524`), `shouldTrace` (`app_runner/root.zig:915`) passes every
record named `runtime.event` — which includes `gpu_surface_frame` and `audio`,
emitted once per rendered frame and per audio callback.

`debug.appendFile` (`debug/root.zig:164-171`) does a full open, stat, write,
close per record:

    var file = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);

And it runs on the platform message loop thread: `windowsCallback`
(`platform/windows/root.zig:567`) is a `callconv(.c)` callback from the host's
pump, calling `RunState.emit` (`:557`), which invokes the runtime event handler
synchronously.

## Measured impact

On a Linux dev box running the SUB/WAVE player:
`~/.local/state/dev.subwave.player/logs/native-sdk.jsonl` reached **423 MB**
over twenty days with no rotation and no size cap. Sampling the last 20 MB —
162,686 records over 10,430 seconds, ~15.6/s sustained:

| event | rate |
| --- | --- |
| `audio` | 7.7/s |
| `gpu_surface_frame` | 7.4/s |
| `effects_wake` | 0.3/s |
| everything else | < 0.3/s |

That is a floor, not a ceiling — both high-rate events are gated on the window
being visibly on screen.

On Windows behind Bitdefender's real-time minifilter, which scans on open and
close, this stalls the message pump. Symptoms: solid white client area, busy
cursor on minimize/maximize/edge-resize, near-zero CPU (blocked, not
spinning), audio unaffected because it runs on its own thread. It worsens as
the file grows, so it presents as a regression with no system change. Reported
as getsubwave/subwave-desktop#23.

## Asks

1. **`FileTraceSink` should hold its handle open** rather than
   open/stat/write/close per record. This alone removes the per-frame
   syscall storm and the AV scan trigger.
2. **Per-frame events should not be traced at the default level.** Today
   `-Dtrace` cannot express this: `shouldTrace` filters on `record.name`, and
   every one of these records is named `runtime.event` with the kind in
   `fields`. Either exclude high-rate events from `.events`, or put the event
   kind in `record.name` so the substring mode can filter them.
3. **Bound the file.** Rotation or a size cap; today it grows forever.

## Our workaround

Every shipping build passes `-Dtrace=off`, guarded by
`scripts/check-release-flags.sh`. The app carries its own bounded breadcrumb
log (`src/diag.zig`) instead. Panic capture is unaffected —
`installPanicCapture` runs outside the trace gate.
```

- [ ] **Step 8: Record it in the SDK notes**

Append a section to `docs/sdk-notes.md`:

```markdown
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
The upstream request is `docs/sdk-trace-log-request.md`.
```

- [ ] **Step 9: Run the full suite**

Run: `native check && native test`
Expected: both pass. No source changed, so this is a regression check only.

- [ ] **Step 10: Commit**

```bash
git add .github/workflows/ scripts/check-release-flags.sh docs/sdk-trace-log-request.md docs/sdk-notes.md
git commit -m "Ship with -Dtrace=off: the SDK's per-frame trace log stalls the Windows message loop

The SDK writes one runtime.event record per rendered frame and per audio
callback, and each record is a full open/stat/write/close on a log file that
grows without bound — inline on the message loop thread. On Windows behind
Bitdefender's minifilter that stalls the pump: white client area, busy cursor,
near-zero CPU, audio still playing. That is issue #23.

Panic capture is outside the trace gate and survives the flag.
scripts/check-release-flags.sh fails CI if any workflow drops it."
```

---

### Task 2: `src/diag.zig` — the bounded breadcrumb log

**Files:**
- Create: `src/diag.zig`
- Modify: `src/tests.zig:9-18` (add to the comptime import block)

**Interfaces:**
- Consumes: nothing.
- Produces, all used by Tasks 3 and 4:
  - `pub fn open(io: std.Io, log_dir: []const u8) void` — rolls the previous run, truncates and opens the current log, records the start instant. Silent no-op on any failure.
  - `pub fn close(io: std.Io) void`
  - `pub fn print(comptime fmt: []const u8, args: anytype) void` — one timestamped line. No-op when unopened or capped.
  - `pub fn reclaimSdkLog(io: std.Io, path: []const u8, max_bytes: u64) void` — deletes an oversized SDK trace log. Silent no-op on any failure.
  - `pub fn dir() []const u8` — the resolved log directory, empty when unopened.
  - `pub const cap_bytes: u64 = 256 * 1024;`
  - `pub const sdk_reclaim_bytes: u64 = 8 * 1024 * 1024;`

- [ ] **Step 1: Write the failing tests**

Create `src/diag.zig` containing only the tests at first, so they fail to compile against the missing implementation:

```zig
const testing = std.testing;

// Each test gets its own directory so a failure in one cannot mask another.
fn testDir(comptime name: []const u8) []const u8 {
    return ".zig-cache/diag-test-" ++ name;
}

fn readBack(comptime name: []const u8, file: []const u8, buf: []u8) []const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ testDir(name), file }) catch unreachable;
    const n = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(buf.len)) catch return "";
    defer testing.allocator.free(n);
    @memcpy(buf[0..n.len], n);
    return buf[0..n.len];
}

test "open writes into the log dir and print appends timestamped lines" {
    const d = testDir("basic");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    defer close(testing.io);
    try testing.expectEqualStrings(d, dir());

    print("hello {s}", .{"world"});
    print("second", .{});

    var buf: [4096]u8 = undefined;
    const text = readBack("basic", "subwave.log", &buf);
    try testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, text, "second") != null);
    // Every line carries a relative-time prefix so a gap is visible.
    try testing.expect(std.mem.startsWith(u8, text, "[+"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
}

test "a second open rolls the previous run aside" {
    const d = testDir("roll");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    print("first run", .{});
    close(testing.io);

    open(testing.io, d);
    print("second run", .{});
    close(testing.io);

    var buf: [4096]u8 = undefined;
    const prev = readBack("roll", "subwave.prev.log", &buf);
    try testing.expect(std.mem.indexOf(u8, prev, "first run") != null);

    var buf2: [4096]u8 = undefined;
    const cur = readBack("roll", "subwave.log", &buf2);
    try testing.expect(std.mem.indexOf(u8, cur, "second run") != null);
    // The fresh run must not inherit the old run's lines.
    try testing.expect(std.mem.indexOf(u8, cur, "first run") == null);
}

test "the byte cap stops writing and says so exactly once" {
    const d = testDir("cap");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    defer close(testing.io);
    // 64 bytes of payload per line, well past cap_bytes over this many lines.
    var i: usize = 0;
    while (i < (cap_bytes / 32) + 100) : (i += 1) {
        print("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .{});
    }

    const size = std.Io.Dir.cwd().statFile(testing.io, ".zig-cache/diag-test-cap/subwave.log", .{}) catch unreachable;
    // Capped, with headroom for the final notice line.
    try testing.expect(size.size <= cap_bytes + 128);

    var buf: [512]u8 = undefined;
    const n = std.Io.Dir.cwd().readFileAlloc(testing.io, ".zig-cache/diag-test-cap/subwave.log", testing.allocator, .limited(cap_bytes + 256)) catch unreachable;
    defer testing.allocator.free(n);
    _ = buf;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, n, "log capped"));
}

test "print is a silent no-op when never opened" {
    // No open() call. Must not crash and must not create anything.
    print("this goes nowhere", .{});
    try testing.expectEqualStrings("", dir());
}

test "reclaimSdkLog deletes only an oversized file" {
    const d = testDir("reclaim");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    std.Io.Dir.cwd().createDirPath(testing.io, d) catch unreachable;

    const small = d ++ "/small.jsonl";
    const big = d ++ "/big.jsonl";
    std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = small, .data = "tiny" }) catch unreachable;
    const payload = [_]u8{'x'} ** 4096;
    std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = big, .data = &payload }) catch unreachable;

    reclaimSdkLog(testing.io, small, 1024);
    reclaimSdkLog(testing.io, big, 1024);

    _ = std.Io.Dir.cwd().statFile(testing.io, small, .{}) catch return testing.expect(false) catch unreachable;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, big, .{}));

    // A missing path is a no-op, not a crash.
    reclaimSdkLog(testing.io, d ++ "/absent.jsonl", 1024);
}
```

Add `_ = @import("diag.zig");` to the comptime block in `src/tests.zig` (after the `links.zig` line).

- [ ] **Step 2: Run tests to verify they fail**

Run: `native test`
Expected: FAIL — compile errors, `open`/`close`/`print`/`dir`/`cap_bytes`/`reclaimSdkLog` undeclared, plus a missing `std` import.

- [ ] **Step 3: Write the implementation**

Prepend to `src/diag.zig`, above the tests:

```zig
//! Bounded diagnostic breadcrumb log — the file a user attaches to a bug
//! report.
//!
//! TWO RULES, both learned from issue #23:
//!
//! 1. NEVER log per-frame or per-audio-event. The SDK's own trace sink does
//!    exactly that, with a full open/stat/write/close per record on an
//!    unbounded file, inline on the message loop thread. On Windows behind an
//!    AV minifilter it stalls the pump outright. Shipping builds disable it
//!    with -Dtrace=off; this module is its replacement, and copying its
//!    shape would reintroduce the bug. The heartbeat is driven by elapsed
//!    time (the existing 1s tick), never by frame count.
//!
//! 2. This writes SYNCHRONOUSLY and does NOT route through the effects
//!    channel, against the architecture rule in CLAUDE.md. That is
//!    deliberate and the exemption is this module only: an fx-routed log
//!    cannot record the failure of the loop that runs fx, which is precisely
//!    the failure worth recording.
//!
//! The handle is opened once in main() and held for the process lifetime.
//! Everything is a silent no-op on failure — the app runs without
//! diagnostics rather than not at all, matching settings.zig's posture.
//!
//! Single-threaded by construction: main() opens it, and every other caller
//! is inside update(), which runs on the loop thread.

const std = @import("std");
const native_sdk = @import("native_sdk");

/// Hard ceiling on one run's log. Evidence, not telemetry.
pub const cap_bytes: u64 = 256 * 1024;

/// An SDK trace log bigger than this is a pre-`-Dtrace=off` install's
/// leftovers; reclaim it once at startup.
pub const sdk_reclaim_bytes: u64 = 8 * 1024 * 1024;

const State = struct {
    io: std.Io = undefined,
    file: ?std.Io.File = null,
    offset: u64 = 0,
    capped: bool = false,
    start_ms: i64 = 0,
    dir_buf: [1024]u8 = undefined,
    dir_len: usize = 0,
};

var state: State = .{};

/// The resolved log directory, or "" when the log was never opened.
pub fn dir() []const u8 {
    return state.dir_buf[0..state.dir_len];
}

/// Roll the previous run aside and open a fresh log in `log_dir`.
/// Silent no-op if anything fails.
pub fn open(io: std.Io, log_dir: []const u8) void {
    if (log_dir.len == 0 or log_dir.len > state.dir_buf.len) return;
    const platform = native_sdk.app_dirs.currentPlatform();
    var cur_buf: [1200]u8 = undefined;
    var prev_buf: [1200]u8 = undefined;
    const cur = native_sdk.app_dirs.join(platform, &cur_buf, &.{ log_dir, "subwave.log" }) catch return;
    const prev = native_sdk.app_dirs.join(platform, &prev_buf, &.{ log_dir, "subwave.prev.log" }) catch return;

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, log_dir) catch {};
    // A hang means the user restarts before thinking to grab the file, so
    // one run of history is kept. Missing source is fine — first launch.
    cwd.rename(io, cur, cwd, prev) catch {};

    const file = cwd.createFile(io, cur, .{ .truncate = true }) catch return;
    @memcpy(state.dir_buf[0..log_dir.len], log_dir);
    state.dir_len = log_dir.len;
    state.io = io;
    state.file = file;
    state.offset = 0;
    state.capped = false;
    state.start_ms = native_sdk.nowMs();
}

pub fn close(io: std.Io) void {
    if (state.file) |f| f.close(io);
    state.file = null;
    state.dir_len = 0;
    state.offset = 0;
    state.capped = false;
}

/// One timestamped line. No-op when unopened or capped. Lines longer than
/// the buffer are dropped rather than truncated mid-format.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const file = state.file orelse return;
    if (state.capped) return;

    var line_buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&line_buf);
    const since_ms = native_sdk.nowMs() - state.start_ms;
    w.print("[+{d}.{d:0>3}s] ", .{ @divTrunc(since_ms, 1000), @rem(since_ms, 1000) }) catch return;
    w.print(fmt, args) catch return;
    w.writeByte('\n') catch return;
    const line = w.buffered();

    if (state.offset + line.len > cap_bytes) {
        state.capped = true;
        const notice = "[+0.000s] log capped\n";
        file.writePositionalAll(state.io, notice, state.offset) catch {};
        state.offset += notice.len;
        return;
    }
    file.writePositionalAll(state.io, line, state.offset) catch return;
    state.offset += line.len;
}

/// Delete the SDK's trace log if it grew past `max_bytes`. Pre-`-Dtrace=off`
/// installs carry hundreds of megabytes of per-frame records; this reclaims
/// it once, and keeps the machine safe if a future SDK re-enables tracing.
pub fn reclaimSdkLog(io: std.Io, path: []const u8, max_bytes: u64) void {
    var cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return;
    if (st.size <= max_bytes) return;
    cwd.deleteFile(io, path) catch {};
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `native test`
Expected: PASS, all six `diag` tests green alongside the existing suite.

If the cap test's `readFileAlloc` limit trips, raise the `.limited(...)` argument rather than loosening the assertion — the point of that test is that the file stopped growing.

- [ ] **Step 5: Commit**

```bash
git add src/diag.zig src/tests.zig
git commit -m "Add a bounded diagnostic breadcrumb log

Held-open handle, per-run truncate with one run of history, 256 KB cap, and
a silent no-op when unopened so the test suite writes nothing. Documents why
it bypasses the effects channel: an fx-routed log cannot record the failure
of the loop that runs fx."
```

---

### Task 3: Open the log at startup and reclaim the old SDK log

**Files:**
- Modify: `src/main.zig` (imports near line 11, and `main()` around lines 468-482)

**Interfaces:**
- Consumes: `diag.open`, `diag.close`, `diag.print`, `diag.dir`, `diag.reclaimSdkLog`, `diag.sdk_reclaim_bytes` from Task 2.
- Produces: `pub const bundle_id = "dev.subwave.player";` in `src/main.zig`, used to resolve the SDK log directory. Task 5 consumes `diag.dir()`.

- [ ] **Step 1: Add the import and the bundle id constant**

In `src/main.zig`, after the `const api = @import("api.zig");` line:

```zig
const diag = @import("diag.zig");
```

`runWithOptions` currently passes the bundle id as a literal. Hoist it so the log-dir resolution and the runner cannot drift apart. Above `const canvas_label = "main-canvas";`:

```zig
// The SDK keys its per-app directories (logs, window state) on the bundle id,
// so diag must resolve the log dir from the same string runWithOptions gets.
pub const bundle_id = "dev.subwave.player";
```

Then in the `runWithOptions` call, replace `.bundle_id = "dev.subwave.player",` with `.bundle_id = bundle_id,`.

- [ ] **Step 2: Open the log in `main()`**

In `main()`, immediately after the `settings.loadFromDisk(&app_state.model, init.io);` line and before the `executablePath` call, insert:

```zig
    // Diagnostics open before anything else can fail interestingly. The SDK
    // resolves the same directory for last-panic.txt, so everything a user
    // needs to attach to a bug report lands in one folder.
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    if (native_sdk.debug.resolveLogPaths(
        &log_buffers,
        bundle_id,
        native_sdk.debug.envFromMap(init.environ_map),
        init.environ_map.get("NATIVE_SDK_LOG_DIR"),
    )) |paths| {
        // Pre-0.8.1 installs carry a native-sdk.jsonl grown to hundreds of
        // megabytes by the SDK's per-frame trace sink — the issue #23 stall.
        // Shipping builds now pass -Dtrace=off, but the old file is still on
        // disk and still gets scanned by AV on every access.
        diag.reclaimSdkLog(init.io, paths.log_file, diag.sdk_reclaim_bytes);
        diag.open(init.io, paths.log_dir);
    } else |_| {}
    defer diag.close(init.io);
```

- [ ] **Step 3: Write the boot breadcrumbs**

Immediately after the `SUBWAVE_STATION_URL` block in `main()` — so the station it reports is the one that actually won — insert:

```zig
    diag.print("subwave {s} {s}-{s} start", .{
        updater.version,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    diag.print("log dir {s}", .{diag.dir()});
    diag.print("settings {s}", .{app_state.model.settings_path});
    diag.print("phase {s} station {s}", .{
        @tagName(app_state.model.phase),
        if (app_state.model.base.len > 0) app_state.model.base else "(none)",
    });
```

`main.zig` already imports `builtin`. Add `const updater = @import("update.zig");` alongside the other imports if it is not already there — check first; `views.zig` reaches `updater.version` through the Model's `app_version()` accessor, so `main.zig` may not import it yet.

- [ ] **Step 4: Build and run to verify the log appears**

Run:

```bash
native build -Dcpu=baseline -Dtrace=off
timeout 8 ./zig-out/bin/subwave-desktop || true
cat ~/.local/state/dev.subwave.player/logs/subwave.log
```

Expected: four lines, each prefixed `[+0.…s] `, naming the version, the log dir, the settings path, and the phase.

**Do not set `SUBWAVE_STATION_URL` for this run** — the env override persists into the real `settings.json`. If you need to test the player phase locally, back up `~/.config/subwave-player/settings.json` first and restore it after.

- [ ] **Step 5: Verify the reclaim path**

Run:

```bash
ls -la ~/.local/state/dev.subwave.player/logs/
```

Expected: `native-sdk.jsonl` is gone if it was over 8 MB (it was 423 MB on the dev box), and `subwave.log` is present and small.

- [ ] **Step 6: Run the suite**

Run: `native check && native test`
Expected: PASS. `main()` is not exercised by the suite, so `diag` stays closed there and writes nothing — confirm no stray `subwave.log` appears in the repo root.

- [ ] **Step 7: Commit**

```bash
git add src/main.zig
git commit -m "Open the diagnostic log at startup and reclaim the old SDK trace log

Boot breadcrumbs land before the window opens, so a failure on the way into
the player has context above it. Installs predating -Dtrace=off carry a
native-sdk.jsonl grown to hundreds of megabytes; delete it once."
```

---

### Task 4: Breadcrumbs and the heartbeat in the reducer

**Files:**
- Modify: `src/model.zig` — imports, `Model` (two new fields), `startStream` (line 1505), `scheduleReconnect` (line 1726), `tuneOut` (line 2103), the `.tick_second` arm (line 2214), the `.audio_event` arm (line 2754), the settings `phase = .player` site (line 1653), the `.ob_tune_in` arm (line 3276)

**Interfaces:**
- Consumes: `diag.print` from Task 2.
- Produces: two `Model` fields consumed by nothing else — `hb_ticks: u8 = 0`, `hb_audio_events: u32 = 0`.

- [ ] **Step 1: Write the failing test**

Add to the test block at the end of `src/model.zig`:

```zig
test "the heartbeat fires every fifth tick and resets the audio-event count" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};

    // Audio events are counted, never logged — the arm must not emit per event.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        update(&m, .{ .audio_event = .{ .key = keys.audio, .kind = .position, .position_ms = 1000 } }, &fx);
    }
    try testing.expectEqual(@as(u32, 40), m.hb_audio_events);

    // Four ticks accumulate without reaching the boundary.
    i = 0;
    while (i < 4) : (i += 1) {
        update(&m, .{ .tick_second = .{ .key = keys.second_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    }
    try testing.expectEqual(@as(u8, 4), m.hb_ticks);
    try testing.expectEqual(@as(u32, 40), m.hb_audio_events);

    // The fifth is the heartbeat boundary: both counters reset.
    update(&m, .{ .tick_second = .{ .key = keys.second_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(@as(u8, 0), m.hb_ticks);
    try testing.expectEqual(@as(u32, 0), m.hb_audio_events);

    // A tick that did not fire must not advance the heartbeat.
    update(&m, .{ .tick_second = .{ .key = keys.second_timer, .outcome = .rejected, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(@as(u8, 0), m.hb_ticks);
}
```

`Effects.init(testing.allocator)` with `fx.executor = .fake` is the pattern the
existing suite already uses — see the sleep-timer test near line 3531, which
drives the same `.tick_second` message.

`EffectTimerOutcome` is `enum { fired, rejected }` (`runtime/effects.zig:578`) —
`.rejected` is the only non-firing member, and the last assertion is that the
early return at the top of the arm still guards the counter.

- [ ] **Step 2: Run the test to verify it fails**

Run: `native test`
Expected: FAIL — `hb_audio_events` and `hb_ticks` are not fields of `Model`.

- [ ] **Step 3: Add the import and the fields**

At the top of `src/model.zig`, alongside the other module imports:

```zig
const diag = @import("diag.zig");
```

In `Model`, next to the other transport-adjacent fields (near `transport: Transport = .playing,` at line 257):

```zig
    // Heartbeat bookkeeping. The 1s tick drives a 5s diagnostic line; the
    // audio-event count is the closest honest proxy for "is the loop still
    // turning" (the model has no frame counter, and the audio channel is the
    // ~25 Hz animation clock). NEVER log per event — count here, emit on the
    // tick. See src/diag.zig's header and issue #23.
    hb_ticks: u8 = 0,
    hb_audio_events: u32 = 0,
```

- [ ] **Step 4: Emit the heartbeat from the second tick**

Replace the `.tick_second` arm body (line 2214) with:

```zig
        .tick_second => |t| {
            if (t.outcome != .fired) return;
            model.now_wall_ms = native_sdk.nowMs();
            model.hb_ticks += 1;
            if (model.hb_ticks >= 5) {
                model.hb_ticks = 0;
                diag.print("hb phase={s} transport={s} audio_events={d} retry={d}", .{
                    @tagName(model.phase),
                    @tagName(model.transport),
                    model.hb_audio_events,
                    model.retry,
                });
                model.hb_audio_events = 0;
            }
            if (model.sleep_deadline_ms > 0 and model.now_wall_ms >= model.sleep_deadline_ms) {
                disarmSleep(model, fx);
                tuneOut(model, fx);
            }
        },
```

- [ ] **Step 5: Count audio events without logging them**

In the `.audio_event` arm (line 2754), add the counter increment as the first statement inside the arm, before the `switch (e.kind)`:

```zig
        .audio_event => |e| {
            // Counted, never logged: this fires ~25 times a second. The
            // heartbeat reports the count once per 5s. See issue #23.
            model.hb_audio_events +|= 1;
            switch (e.kind) {
```

Leave the rest of the arm untouched.

- [ ] **Step 6: Add the transition and failure breadcrumbs**

Five single-line additions, each at a point that is a real fork in the run:

In `startStream` (line 1505), immediately before `model.transport = .playing;`:

```zig
    diag.print("stream start format={s}", .{model.effectiveFormat().id()});
```

`StreamFormat.id()` is `src/stream_format.zig:34` and returns the short
settings-facing name (`"mp3"`, `"aac"`, …), which is what belongs in a log line.
`label()` and `detail()` are the human-facing display strings — do not use those
here.

In `scheduleReconnect` (line 1726), immediately before the `fx.startTimer` call so the computed delay is in scope:

```zig
    diag.print("stream reconnect retry={d} delay_ms={d} format={s}", .{ model.retry, delay, model.effectiveFormat().id() });
```

In `tuneOut` (line 2103), as the first statement:

```zig
    diag.print("stream stop", .{});
```

At the settings-load transition (line 1653), immediately after `model.phase = .player;`:

```zig
                diag.print("phase player (saved station)", .{});
```

In the `.ob_tune_in` arm (line 3276), immediately after `model.phase = .player;`:

```zig
                diag.print("phase player (onboarding complete)", .{});
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `native test`
Expected: PASS. `diag` is unopened in the suite, so every `diag.print` here is a no-op — that is exactly what the "silent no-op when never opened" test in Task 2 guarantees.

- [ ] **Step 8: Verify a real run produces a heartbeat**

Back up settings first, because the env override persists:

```bash
cp ~/.config/subwave-player/settings.json /tmp/settings.json.bak
native build -Dcpu=baseline -Dtrace=off
SUBWAVE_STATION_URL=http://127.0.0.1:9 timeout 20 ./zig-out/bin/subwave-desktop || true
cp /tmp/settings.json.bak ~/.config/subwave-player/settings.json
cat ~/.local/state/dev.subwave.player/logs/subwave.log
```

Expected: boot lines, `phase player`, `stream start format=…`, at least one `stream reconnect` (the discard port refuses), and roughly three `hb …` lines across 20 seconds. Confirm there is **no** line-per-frame and no line-per-audio-event.

- [ ] **Step 9: Commit**

```bash
git add src/model.zig
git commit -m "Log phase, stream and heartbeat breadcrumbs from the reducer

The 5s heartbeat carries phase, transport and the count of audio events since
the last beat. That count separates a dead loop (heartbeats stop) from a live
loop with a dead feed (heartbeats continue, count reads zero) — the question
issue #23 spent four rounds of screenshots answering."
```

---

### Task 5: Show the log folder in the back panel

Optional by design. If the row cannot be built inside the existing widget vocabulary, drop it and say so in the commit for Task 4 — the log path is already in the log's own first line. Do **not** invent a widget or add a runtime path to a command line.

**Files:**
- Modify: `src/model.zig` (a `Model` accessor near `app_version` at line 957)
- Modify: `src/views/player-sheets.native` (the `SERVICE` section, around line 107-119)

**Interfaces:**
- Consumes: `diag.dir()` from Task 2.
- Produces: `pub fn log_dir_value(self: *const Model) []const u8` on `Model`, referenced from markup as `{log_dir_value}`.

- [ ] **Step 1: Write the failing test**

`src/tests.zig` already builds and lays out every fragment against the Model across all branches, so a markup field that does not exist on the Model is a compile error. Add an explicit assertion to the `src/model.zig` test block:

```zig
test "log_dir_value reports the diagnostic log folder" {
    const m: Model = .{};
    // Unopened in the suite, so it reads empty rather than crashing.
    try testing.expectEqualStrings("", m.log_dir_value());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `native test`
Expected: FAIL — no member named `log_dir_value`.

- [ ] **Step 3: Add the accessor**

In `src/model.zig`, next to `app_version` (line 957):

```zig
    pub fn log_dir_value(self: *const Model) []const u8 {
        _ = self;
        return diag.dir();
    }
```

- [ ] **Step 4: Add the row**

In `src/views/player-sheets.native`, the `SERVICE` section currently only exists inside `<if test="{update_available}">` (line 107). Move the `<use template="section-label" title="SERVICE"/>` out of that conditional so the section is always present, then add the log row after the update row's closing `</if>`:

```xml
            <use template="section-label" title="SERVICE"/>
            <if test="{update_available}">
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
            <!-- Display only. The opener seam bakes its URLs at comptime
                 (links.zig) so nothing runtime-derived reaches a command
                 line; a folder path is runtime-derived, so this row shows
                 the path rather than launching a file manager. -->
            <column gap="1" padding="10">
              <text>Diagnostic log</text>
              <text size="sm" foreground="text_muted" wrap="true">{log_dir_value}</text>
            </column>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `native check && native test`
Expected: PASS. `native check` validates the markup against the Model contract; `native test` lays out every fragment including this branch.

- [ ] **Step 6: Verify it renders**

```bash
native build -Dautomation=true -Dcpu=baseline -Dtrace=off
./zig-out/bin/subwave-desktop &
native automate wait
native automate screenshot main-canvas
```

Open `.zig-cache/native-sdk-automation/screenshot-main-canvas.png` and confirm the back panel shows the row with a real path. Kill the app by pid when done — `pkill -f` matches its own wrapper shell in this harness.

- [ ] **Step 7: Commit**

```bash
git add src/model.zig src/views/player-sheets.native
git commit -m "Show the diagnostic log folder in the back panel

Display only: links.zig bakes its opener URLs at comptime so nothing
runtime-derived reaches a command line, and a log folder path is
runtime-derived. Reading the path is most of the value."
```

---

### Task 6: A Windows smoke test that reaches the player

**Files:**
- Modify: `.github/workflows/release-windows.yml:112-139`
- Modify: `.github/workflows/ci.yml` (new step after `Build`)

**Interfaces:**
- Consumes: nothing from earlier tasks at build time. The artifact upload references `subwave.log`, produced by Tasks 2-4.
- Produces: nothing.

- [ ] **Step 1: Rewrite the release smoke step**

Replace the body of the `Smoke-test on real Windows` step in `.github/workflows/release-windows.yml` (currently lines 112-139) with:

```yaml
      - name: Smoke-test on real Windows
        # The whole reason this job runs on windows-latest instead of
        # cross-compiling. Rebuilds with the automation harness (the shipped
        # zip is already sealed above, so this binary never reaches anyone).
        #
        # This USED to launch with no station configured, so the app parked on
        # onboarding, reported ready, and exited — it never entered the player
        # and could not have caught issue #23. SUBWAVE_STATION_URL points it
        # at the discard port: main() takes the override, phase becomes
        # .player with no network needed, every fetch fails fast, and the
        # frame loop and audio start path both run. That is the exact
        # transition where #23 goes blank.
        #
        # NOTE: the override persists into settings.json on the machine that
        # runs it. Fine on a throwaway runner, destructive on a dev box.
        #
        # UNPROVEN: GitHub's Windows runners execute in a service session. If
        # automation turns out to be unreachable there, narrow this to a
        # launch-and-survive check rather than deleting it.
        timeout-minutes: 6
        env:
          SUBWAVE_STATION_URL: http://127.0.0.1:9
        run: |
          native build -Dautomation=true -Dcpu=baseline -Dtrace=off
          app="zig-out/bin/subwave-desktop.exe"
          if [ ! -f "$app" ]; then
            echo "error: automation build produced no exe at $app" >&2
            ls -la zig-out/bin/ >&2
            exit 1
          fi
          "./$app" &
          app_pid=$!
          fail=0
          if native automate wait; then
            echo "app reported ready on Windows"
          else
            echo "error: app did not come up under automation" >&2
            fail=1
          fi
          # Every assert below requires the app to service its automation
          # channel, so a stalled message loop fails on timeout instead of
          # passing. gpu_nonblank is the host's own frame sampling — a solid
          # white client area reads false. gpu_frame advancing past zero
          # catches a surface that presented once and froze.
          # No `|` alternation: native automate assert does not support it.
          if [ "$fail" -eq 0 ]; then
            native automate assert --timeout-ms 30000 'gpu_nonblank=true' || fail=1
          fi
          if [ "$fail" -eq 0 ]; then
            native automate assert --timeout-ms 30000 'gpu_frame=[1-9]' || fail=1
          fi
          native automate screenshot main-canvas || true
          kill "$app_pid" 2>/dev/null || true
          exit "$fail"

      - name: Upload smoke-test evidence
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: windows-smoke-evidence
          path: |
            .zig-cache/native-sdk-automation/screenshot-main-canvas.png
            ${{ runner.temp }}/../subwave.log
          if-no-files-found: warn
```

The `subwave.log` path under `LOCALAPPDATA` is not knowable from YAML with confidence — leave the placeholder in place for now. Step 4 captures the real path from a CI run and replaces it.

- [ ] **Step 2: Add the same step to CI's Windows leg**

In `.github/workflows/ci.yml`, after the `Build` step, add:

```yaml
      - name: Smoke-test the player phase
        # Windows only: this is where issue #23 lives, and the release
        # workflow's copy of this step only runs at release time. Catching it
        # here blocks a merge instead of surfacing mid-release, which is the
        # same miss that shipped the MP3-only Windows build.
        if: runner.os == 'Windows'
        timeout-minutes: 6
        env:
          SUBWAVE_STATION_URL: http://127.0.0.1:9
        run: |
          native build -Dautomation=true -Dcpu=baseline -Dtrace=off
          "./zig-out/bin/subwave-desktop.exe" &
          app_pid=$!
          fail=0
          native automate wait || fail=1
          if [ "$fail" -eq 0 ]; then
            native automate assert --timeout-ms 30000 'gpu_nonblank=true' || fail=1
          fi
          if [ "$fail" -eq 0 ]; then
            native automate assert --timeout-ms 30000 'gpu_frame=[1-9]' || fail=1
          fi
          kill "$app_pid" 2>/dev/null || true
          exit "$fail"
```

- [ ] **Step 3: Verify the assertions locally on Linux first**

The patterns must match a real snapshot before they are trusted on a runner that is harder to debug. Back up settings, because the override persists:

```bash
cp ~/.config/subwave-player/settings.json /tmp/settings.json.bak
native build -Dautomation=true -Dcpu=baseline -Dtrace=off
SUBWAVE_STATION_URL=http://127.0.0.1:9 ./zig-out/bin/subwave-desktop &
native automate wait
native automate snapshot | grep -o 'gpu_nonblank=[a-z]*'
native automate snapshot | grep -o 'gpu_frame=[0-9]*'
native automate assert --timeout-ms 30000 'gpu_nonblank=true'
native automate assert --timeout-ms 30000 'gpu_frame=[1-9]'
```

Expected: `gpu_nonblank=true`, a `gpu_frame` above zero, and both asserts exiting 0.

Then kill the app by pid (`kill <pid>` — `pkill -f` matches its own wrapper shell here) and restore settings:

```bash
cp /tmp/settings.json.bak ~/.config/subwave-player/settings.json
```

**If `gpu_nonblank` reads false on Linux**, do not weaken the assertion. The FFT and frame feeds are gated on the window being visibly on screen — activate the window and retry. If it stays false with the window focused, that is a finding worth reporting before this step proceeds.

- [ ] **Step 4: Capture the real Windows log path for the artifact upload**

The `subwave.log` path in Step 1's artifact block is a placeholder. Add a temporary debug line to the release smoke step:

```bash
          native automate assert --timeout-ms 5000 'gpu_nonblank=true' || true
          echo "LOG DIR: $LOCALAPPDATA"
          find "$LOCALAPPDATA" -name 'subwave*.log' 2>/dev/null || true
```

Push the branch, let CI run the Windows leg, read the path from the log, then replace the placeholder path in the artifact block with the real one and delete the debug line.

- [ ] **Step 5: Verify the guard still passes**

Run: `./scripts/check-release-flags.sh`
Expected: PASS. Both new `native build` invocations carry `-Dtrace=off`.

- [ ] **Step 6: Run the suite**

Run: `native check && native test`
Expected: PASS. No source changed.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/release-windows.yml .github/workflows/ci.yml
git commit -m "Make the Windows smoke test reach the player and assert it presented

It used to launch with no station, park on onboarding, report ready and exit
— it never entered the player, so it could not have caught issue #23.
SUBWAVE_STATION_URL=http://127.0.0.1:9 gets it into the player with no
network. gpu_nonblank and gpu_frame come from the host's own frame sampling,
so a blank white client area fails instead of passing, and every assert
requires a live message loop."
```

---

## After the plan

Two things remain that this plan cannot do:

1. **Ask dejjem to confirm on #23** against a build with `-Dtrace=off`. That is the real verification and the one that closes the issue. Draft the comment separately — the repo's convention is no em dashes and a humanized tone.
2. **File the upstream request** from `docs/sdk-trace-log-request.md` with the SDK maintainers. Ours is a workaround until `FileTraceSink` holds its handle open.
