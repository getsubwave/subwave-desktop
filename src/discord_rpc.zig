//! Discord Rich Presence: build-time client ID + pure IPC payload/frame
//! encoding + local socket path resolution. No I/O here — main.zig's
//! --discord-rpc-helper branch owns the actual socket calls; model.zig
//! owns the fx.spawn/fx.cancel wiring. Kept pure and testable like
//! api.zig/color.zig/spectrum.zig.

const std = @import("std");

// discord.zon lives next to this file (src/discord.zon), not at the repo
// root: Zig 0.16 forbids a relative @import crossing outside the importing
// module's root directory (confirmed general, not zon-specific — a plain
// sibling .zig file at the repo root fails the same "import of file outside
// module path" way), and app.zon only reaches src/*.zig today because the
// SDK's generated build.zig gives it special named-module wiring
// ("app_manifest_zon") that nothing else gets. Same-directory keeps this a
// plain same-module import with no build-graph changes needed.
const discord_config = @import("discord.zon");

/// Empty by default (the checked-in discord.zon placeholder) — see
/// README.md "Discord Rich Presence" for how a builder fills this in.
pub const client_id: []const u8 = discord_config.client_id;
pub const configured_at_build: bool = client_id.len > 0;

/// discord-ipc-0's home varies by platform; this is the fallback chain
/// every third-party Discord RPC client uses. Parameters are passed in
/// explicitly (rather than read from the environment here) so this stays
/// pure and testable.
pub fn resolveSocketPath(buf: []u8, xdg_runtime_dir: ?[]const u8, tmpdir: ?[]const u8, tmp: ?[]const u8) ![]const u8 {
    const base = nonEmpty(xdg_runtime_dir) orelse nonEmpty(tmpdir) orelse nonEmpty(tmp) orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/discord-ipc-0", .{base});
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    if (v) |s| {
        if (s.len > 0) return s;
    }
    return null;
}

// Escapes exactly what SET_ACTIVITY string fields need: quotes,
// backslashes, newlines; drops other raw control bytes. Duplicated from
// model.zig's jsonEscape (same behavior) rather than imported, so this
// module stays a leaf with no dependency on model.zig.
fn jsonEscape(buf: []u8, s: []const u8) []const u8 {
    var w: usize = 0;
    for (s) |ch| {
        if (w + 2 > buf.len) break;
        switch (ch) {
            '"' => {
                buf[w] = '\\';
                buf[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                buf[w] = '\\';
                buf[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                buf[w] = '\\';
                buf[w + 1] = 'n';
                w += 2;
            },
            0x00...0x09, 0x0b...0x1f => {},
            else => {
                buf[w] = ch;
                w += 1;
            },
        }
    }
    return buf[0..w];
}

/// Epoch-millisecond window for the Discord progress bar. `end_ms` null
/// means an open-ended elapsed counter (duration unknown).
pub const Timestamps = struct { start_ms: i64, end_ms: ?i64 = null };

/// The `activity` object body for a SET_ACTIVITY command: details/state
/// text, an optional progress window. `type: 2` (LISTENING) and
/// `status_display_type: 2` (DETAILS) are fixed, not parameterized — this
/// app only ever shows one kind of activity, and status_display_type is
/// what makes the compact status text read as the track itself rather than
/// "Listening to <app name>" (the app name still appears in the full
/// profile popout regardless; that's Discord's, not ours, to control).
/// `url` empty omits `details_url`/`assets.large_url` (the clickable
/// song-title / cover-art link) entirely. Only ever called from main.zig's
/// --discord-rpc-helper process, which has a real wall clock to compute
/// `created_at`/`timestamps` from — model.zig's pure reducer does not (see
/// buildActivityRequestJson for what it sends instead).
///
/// `instance` and `created_at` are sent unconditionally (not just when
/// convenient) because every known-working third-party RPC client does —
/// traced through @xhayper/discord-rpc's ClientUser.setActivity, the
/// library backing a reference app confirmed working end-to-end. Missing
/// them was the actual cause of the presence never rendering: this app was
/// sending a strictly smaller activity object than any proven
/// implementation, and Discord doesn't error on the fields it's missing —
/// it just silently doesn't render what depends on them.
///
/// No `buttons` field: Discord never renders your own activity's buttons
/// back to you in your own client (only other viewers would ever see one),
/// so there's no way to verify one actually works, and it's not worth the
/// settings surface. `url` gets you the same click-through via the details
/// line and cover art instead.
pub fn buildActivityJson(buf: []u8, details: []const u8, state: []const u8, url: []const u8, cover_url: []const u8, created_at_ms: i64, timestamps: ?Timestamps) ![]const u8 {
    var esc: [4][160]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    try w.print("{{\"type\":2,\"status_display_type\":2,\"instance\":false,\"created_at\":{d},\"details\":\"{s}\",\"state\":\"{s}\"", .{
        created_at_ms,
        jsonEscape(&esc[0], details),
        jsonEscape(&esc[1], state),
    });
    if (url.len > 0) {
        // Makes the details line itself a clickable hyperlink to the
        // station — traced from a reference app confirmed working: it sets
        // this (alongside a matching assets.large_url below) from the same
        // "open the station" URL.
        try w.print(",\"details_url\":\"{s}\"", .{jsonEscape(&esc[2], url)});
    }
    // Discord's RPC/IPC channel proxies a plain external image URL directly
    // for `large_image`/`large_url` (unlike the REST API, which needs a
    // pre-registered asset key or an `mp:`-prefixed proxy path) — no extra
    // resolution step needed here. large_url makes the cover art itself
    // clickable, same URL as details_url.
    if (cover_url.len > 0) {
        if (url.len > 0) {
            try w.print(",\"assets\":{{\"large_image\":\"{s}\",\"large_url\":\"{s}\"}}", .{
                jsonEscape(&esc[3], cover_url),
                jsonEscape(&esc[2], url),
            });
        } else {
            try w.print(",\"assets\":{{\"large_image\":\"{s}\"}}", .{jsonEscape(&esc[3], cover_url)});
        }
    }
    if (timestamps) |ts| {
        if (ts.end_ms) |end| {
            try w.print(",\"timestamps\":{{\"start\":{d},\"end\":{d}}}", .{ ts.start_ms, end });
        } else {
            try w.print(",\"timestamps\":{{\"start\":{d}}}", .{ts.start_ms});
        }
    }
    try w.print("}}", .{});
    return w.buffered();
}

/// The lightweight request piped as --discord-rpc-helper's stdin: raw
/// display fields plus (optionally) the live player position — NOT a
/// Discord activity object yet. main.zig's helper turns it into one via
/// buildActivityJson, converting elapsed_ms to absolute epoch timestamps
/// only at the moment it actually sends SET_ACTIVITY (it has a real clock
/// through its Io; model.zig's pure reducer doesn't).
///
/// elapsed_ms is deliberately excluded from the string when
/// include_elapsed is false. model.zig diffs this exact string to decide
/// whether the presence actually needs to change; elapsed advances on
/// every playback tick, so folding it into that comparison would force a
/// full respawn+reconnect of the helper on every now-playing poll instead
/// of only on a real change (track, label, or station).
///
/// A generous size cap for one buildActivityRequestJson output — model.zig
/// sizes its buffers (the persisted signature field and its two scratch
/// buffers) off this one constant rather than picking three separate
/// numbers that would all just need to agree anyway. main.zig's stdin read
/// limit and encodeActivityFrame's body buffer (both 2048) must stay
/// comfortably larger than this; they're sized independently rather than
/// sharing this constant since they're already well clear of it.
pub const activity_request_max = 640;

pub const ActivityRequest = struct {
    details: []const u8 = "",
    state: []const u8 = "",
    url: []const u8 = "",
    cover_url: []const u8 = "",
    duration_s: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub fn buildActivityRequestJson(buf: []u8, req: ActivityRequest, include_elapsed: bool) ![]const u8 {
    var esc: [4][160]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    try w.print("{{\"details\":\"{s}\",\"state\":\"{s}\",\"url\":\"{s}\",\"cover_url\":\"{s}\",\"duration_s\":{d}", .{
        jsonEscape(&esc[0], req.details),
        jsonEscape(&esc[1], req.state),
        jsonEscape(&esc[2], req.url),
        jsonEscape(&esc[3], req.cover_url),
        req.duration_s,
    });
    if (include_elapsed) try w.print(",\"elapsed_ms\":{d}", .{req.elapsed_ms});
    try w.print("}}", .{});
    return w.buffered();
}

/// Opcode-0 handshake: 8-byte header (opcode, length; both little-endian
/// u32) + `{"v":1,"client_id":"<id>"}`.
pub fn encodeHandshakeFrame(buf: []u8, discord_client_id: []const u8) ![]const u8 {
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"v\":1,\"client_id\":\"{s}\"}}", .{discord_client_id});
    return encodeFrame(buf, 0, body);
}

/// Opcode-1 SET_ACTIVITY, wrapping a pre-built `activity_json` body (see
/// `buildActivityJson`) with the command envelope in one wire frame.
pub fn encodeActivityFrame(buf: []u8, pid: i32, activity_json: []const u8) ![]const u8 {
    var body_buf: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"1\",\"args\":{{\"pid\":{d},\"activity\":{s}}}}}", .{ pid, activity_json });
    return encodeFrame(buf, 1, body);
}

fn encodeFrame(buf: []u8, opcode: u32, body: []const u8) ![]const u8 {
    if (buf.len < 8 + body.len) return error.NoSpaceLeft;
    std.mem.writeInt(u32, buf[0..4], opcode, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(body.len), .little);
    @memcpy(buf[8 .. 8 + body.len], body);
    return buf[0 .. 8 + body.len];
}

// ---------------------------------------------------------------- tests
const testing = std.testing;

test "resolveSocketPath prefers XDG_RUNTIME_DIR, then TMPDIR, then TMP, then /tmp" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/run/user/1000/discord-ipc-0", try resolveSocketPath(&buf, "/run/user/1000", "/should/not/win", null));
    try testing.expectEqualStrings("/tmp/xyz/discord-ipc-0", try resolveSocketPath(&buf, null, "/tmp/xyz", null));
    try testing.expectEqualStrings("/tmp/discord-ipc-0", try resolveSocketPath(&buf, null, null, null));
    try testing.expectEqualStrings("/tmp/discord-ipc-0", try resolveSocketPath(&buf, "", "", ""));
}

test "buildActivityJson always sends instance and created_at, and includes details_url only when a URL is given" {
    var buf: [512]u8 = undefined;
    const with_url = try buildActivityJson(&buf, "Night Drive", "The Midnight", "https://sub.wave/station", "", 1_700_000_000_000, null);
    try testing.expectEqualStrings(
        "{\"type\":2,\"status_display_type\":2,\"instance\":false,\"created_at\":1700000000000,\"details\":\"Night Drive\",\"state\":\"The Midnight\",\"details_url\":\"https://sub.wave/station\"}",
        with_url,
    );
    const no_url = try buildActivityJson(&buf, "say \"hi\"", "a\nb", "", "", 0, null);
    try testing.expectEqualStrings("{\"type\":2,\"status_display_type\":2,\"instance\":false,\"created_at\":0,\"details\":\"say \\\"hi\\\"\",\"state\":\"a\\nb\"}", no_url);
}

test "buildActivityJson includes assets.large_image (+ large_url when a station URL is also known) only when a cover URL is given" {
    var buf: [512]u8 = undefined;
    const cover_only = try buildActivityJson(&buf, "Night Drive", "The Midnight", "", "https://sub.wave/cover/abc", 0, null);
    try testing.expect(std.mem.indexOf(u8, cover_only, "\"assets\":{\"large_image\":\"https://sub.wave/cover/abc\"}") != null);

    const cover_and_url = try buildActivityJson(&buf, "Night Drive", "The Midnight", "https://sub.wave/station", "https://sub.wave/cover/abc", 0, null);
    try testing.expect(std.mem.indexOf(u8, cover_and_url, "\"assets\":{\"large_image\":\"https://sub.wave/cover/abc\",\"large_url\":\"https://sub.wave/station\"}") != null);

    const no_cover = try buildActivityJson(&buf, "Night Drive", "The Midnight", "", "", 0, null);
    try testing.expect(std.mem.indexOf(u8, no_cover, "\"assets\"") == null);
}

test "buildActivityJson includes an open-ended or bounded timestamps window" {
    var buf: [512]u8 = undefined;
    const open_ended = try buildActivityJson(&buf, "Night Drive", "The Midnight", "", "", 0, .{ .start_ms = 1_000_000 });
    try testing.expect(std.mem.indexOf(u8, open_ended, "\"timestamps\":{\"start\":1000000}") != null);
    try testing.expect(std.mem.indexOf(u8, open_ended, "\"end\"") == null);

    const bounded = try buildActivityJson(&buf, "Night Drive", "The Midnight", "", "", 0, .{ .start_ms = 1_000_000, .end_ms = 1_240_000 });
    try testing.expect(std.mem.indexOf(u8, bounded, "\"timestamps\":{\"start\":1000000,\"end\":1240000}") != null);
}

test "buildActivityRequestJson includes elapsed_ms only when asked" {
    var buf: [512]u8 = undefined;
    const req: ActivityRequest = .{ .details = "Night Drive", .state = "The Midnight", .url = "https://sub.wave/station", .cover_url = "https://sub.wave/cover/abc", .duration_s = 240, .elapsed_ms = 12_345 };

    const signature = try buildActivityRequestJson(&buf, req, false);
    try testing.expectEqualStrings(
        "{\"details\":\"Night Drive\",\"state\":\"The Midnight\",\"url\":\"https://sub.wave/station\",\"cover_url\":\"https://sub.wave/cover/abc\",\"duration_s\":240}",
        signature,
    );

    const full = try buildActivityRequestJson(&buf, req, true);
    try testing.expectEqualStrings(
        "{\"details\":\"Night Drive\",\"state\":\"The Midnight\",\"url\":\"https://sub.wave/station\",\"cover_url\":\"https://sub.wave/cover/abc\",\"duration_s\":240,\"elapsed_ms\":12345}",
        full,
    );
}

test "encodeHandshakeFrame writes an 8-byte little-endian header then the JSON body" {
    var buf: [256]u8 = undefined;
    const frame = try encodeHandshakeFrame(&buf, "123456789012345678");
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, frame[0..4], .little));
    const body_len = std.mem.readInt(u32, frame[4..8], .little);
    try testing.expectEqual(@as(usize, body_len), frame.len - 8);
    try testing.expectEqualStrings("{\"v\":1,\"client_id\":\"123456789012345678\"}", frame[8..]);
}

test "encodeActivityFrame wraps the activity body in the SET_ACTIVITY envelope" {
    var buf: [512]u8 = undefined;
    const activity = "{\"details\":\"Night Drive\",\"state\":\"The Midnight\"}";
    const frame = try encodeActivityFrame(&buf, 4242, activity);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, frame[0..4], .little));
    const body = frame[8..];
    try testing.expect(std.mem.indexOf(u8, body, "\"cmd\":\"SET_ACTIVITY\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"pid\":4242") != null);
    try testing.expect(std.mem.indexOf(u8, body, activity) != null);
}

test "configured_at_build reflects the checked-in placeholder" {
    try testing.expect(!configured_at_build); // discord.zon's client_id is "" in this repo
}
