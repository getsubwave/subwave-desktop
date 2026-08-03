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
    // A monotonic origin, not a wall-clock instant — see the comment on
    // `native_sdk.monotonicMs()` at the call site in print().
    start_ms: u64 = 0,
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
    // Close any handle already held before anything below can fail and
    // return early — otherwise a second open() without an intervening
    // close() overwrites state.file and leaks the old fd (issue #23 review).
    if (state.file) |f| f.close(io);
    state.file = null;
    const platform = native_sdk.app_dirs.currentPlatform();
    var cur_buf: [1200]u8 = undefined;
    var prev_buf: [1200]u8 = undefined;
    const cur = native_sdk.app_dirs.join(platform, &cur_buf, &.{ log_dir, "subwave.log" }) catch return;
    const prev = native_sdk.app_dirs.join(platform, &prev_buf, &.{ log_dir, "subwave.prev.log" }) catch return;

    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, log_dir) catch {};
    // A hang means the user restarts before thinking to grab the file, so
    // one run of history is kept. Missing source is fine — first launch.
    cwd.rename(cur, cwd, prev, io) catch {};

    const file = cwd.createFile(io, cur, .{ .truncate = true }) catch return;
    @memcpy(state.dir_buf[0..log_dir.len], log_dir);
    state.dir_len = log_dir.len;
    state.io = io;
    state.file = file;
    state.offset = 0;
    state.capped = false;
    // Monotonic, not wall-clock: elapsed time in this log must not jump when
    // the OS clock does (NTP correction, suspend/resume, manual clock
    // change) — see the comment on the subtraction in print().
    state.start_ms = native_sdk.monotonicMs();
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
    // native_sdk.monotonicMs(), not nowMs(): elapsed time here must not move
    // when the OS wall clock does (NTP correction, suspend/resume, a manual
    // clock change), only nowMs() is subject to that — see the SDK's own
    // wall-vs-monotonic split in runtime/clock.zig. Both operands are `u64`,
    // so there is no sign for Zig 0.16's `{d:0>3}` padding to insert (that
    // quirk turned every line's millisecond field into garbage like "0+0"
    // when this used to be `i64` nowMs() math). `-|` saturates instead of
    // wrapping for the documented `monotonicMs() == 0` fallback on targets
    // with no readable clock.
    const since_ms = native_sdk.monotonicMs() -| state.start_ms;
    w.print("[+{d}.{d:0>3}s] ", .{ since_ms / 1000, since_ms % 1000 }) catch return;
    w.print(fmt, args) catch return;
    w.writeByte('\n') catch return;
    const line = w.buffered();

    if (state.offset + line.len > cap_bytes) {
        state.capped = true;
        const notice = "[+0.000s] log capped\n";
        file.writePositionalAll(state.io, notice, state.offset) catch return;
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

test "a second open without close does not leak the first handle" {
    const d = testDir("reopen");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    print("first line", .{});
    // No close() here — open() itself must close the still-live handle
    // rather than overwriting state.file and leaking the fd.
    open(testing.io, d);
    print("second line", .{});

    var buf: [4096]u8 = undefined;
    const text = readBack("reopen", "subwave.log", &buf);
    // The second open() truncates, so only the second line survives.
    try testing.expect(std.mem.indexOf(u8, text, "second line") != null);
    try testing.expect(std.mem.indexOf(u8, text, "first line") == null);

    // The handle from the second open() is still good.
    close(testing.io);
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

    const n = std.Io.Dir.cwd().readFileAlloc(testing.io, ".zig-cache/diag-test-cap/subwave.log", testing.allocator, .limited(cap_bytes + 256)) catch unreachable;
    defer testing.allocator.free(n);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, n, "log capped"));
}

test "print is a silent no-op when never opened" {
    // No open() call. Must not crash and must not create anything.
    print("this goes nowhere", .{});
    try testing.expectEqualStrings("", dir());
}

test "the millisecond field is zero-padded digits with no sign" {
    // Regression test for the Zig 0.16 signed-integer padding bug: `{d:0>3}`
    // against an `i64` renders 7 as "0+7" (a literal '+' where a padding
    // zero belongs), turning every timestamp into garbage like "[+0.0+0s]".
    // A stalled message loop is diagnosed by the gap between the last
    // timestamp and the crash, so a malformed millisecond field defeats the
    // whole point of this log — this must fail if the '+' ever creeps back.
    const d = testDir("timestamp");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    defer close(testing.io);
    // Force a small, single-digit millisecond remainder that requires
    // zero-padding — exactly the shape (e.g. 7ms) that exposed the bug.
    state.start_ms -= 7;
    print("tick", .{});

    var buf: [4096]u8 = undefined;
    const text = readBack("timestamp", "subwave.log", &buf);

    const dot = std.mem.indexOf(u8, text, ".") orelse return testing.expect(false) catch unreachable;
    const suffix = std.mem.indexOf(u8, text, "s] ") orelse return testing.expect(false) catch unreachable;
    try testing.expect(suffix > dot);
    const ms_field = text[dot + 1 .. suffix];

    // Exactly 3 digits, all numeric — a '+' anywhere in here is the bug.
    try testing.expectEqual(@as(usize, 3), ms_field.len);
    for (ms_field) |c| try testing.expect(c >= '0' and c <= '9');
    const parsed_ms = std.fmt.parseInt(u32, ms_field, 10) catch unreachable;
    try testing.expect(parsed_ms >= 7);
}

test "print saturates instead of underflowing when start_ms is ahead of the clock" {
    // Regression test for the finding that replaced nowMs() with
    // monotonicMs(): the original fix cast a signed remainder to u64 and
    // reasoned "since_ms can never be negative" — false, because nowMs() is
    // wall-clock REALTIME and jumps on an NTP correction or suspend/resume,
    // which can make since_ms negative and the @intCast an out-of-range
    // panic (Debug/ReleaseSafe) or UB (ReleaseFast). This simulates the
    // analogous skew directly against the current implementation: start_ms
    // recorded ahead of the monotonic reading print() sees. The `-|`
    // saturating subtraction must clamp to 0, never panic or wrap around to
    // a huge value.
    const d = testDir("skew");
    std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};

    open(testing.io, d);
    defer close(testing.io);
    state.start_ms = native_sdk.monotonicMs() + 1_000_000;
    print("skewed", .{});

    var buf: [4096]u8 = undefined;
    const text = readBack("skew", "subwave.log", &buf);
    // No panic reaching here is itself most of the assertion; also check the
    // line is well-formed rather than a huge wrapped number.
    try testing.expect(std.mem.startsWith(u8, text, "[+0.000s] skewed"));
}

test "reclaimSdkLog deletes only an oversized file" {
    // `d` feeds `++` below, which requires a comptime-known operand — force
    // comptime evaluation of the call rather than relying on the runtime
    // slice testDir() otherwise returns.
    const d = comptime testDir("reclaim");
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
