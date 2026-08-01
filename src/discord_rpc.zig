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
/// README.md "Discord Rich Presence" for how a builder fills this in. This
/// is only the build-time *default*: a listener-entered ID from the Discord
/// sheet (model.discord_client_id, persisted in settings.json) takes
/// precedence, travelling to the helper inside the ActivityRequest.
pub const client_id: []const u8 = discord_config.client_id;
pub const configured_at_build: bool = client_id.len > 0;

/// A Discord application ID is a snowflake: 17-20 ASCII digits. Gate for
/// both the sheet's input field and the settings.json apply path (a
/// hand-edited invalid ID is ignored rather than half-working).
pub fn isValidClientId(s: []const u8) bool {
    if (s.len < 17 or s.len > 20) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The socket's home varies by platform; the base-dir fallback chain here
/// is the one every third-party Discord RPC client uses. `subdir` ("" for
/// a regular install; see socket_subdirs) and `n` (0-9) pick the candidate
/// within that base — main.zig's helper scans subdir x n the same way the
/// Windows named-pipe path scans discord-ipc-N. Parameters are passed in
/// explicitly (rather than read from the environment here) so this stays
/// pure and testable.
pub fn resolveSocketPath(buf: []u8, xdg_runtime_dir: ?[]const u8, tmpdir: ?[]const u8, tmp: ?[]const u8, subdir: []const u8, n: u8) ![]const u8 {
    const base = nonEmpty(xdg_runtime_dir) orelse nonEmpty(tmpdir) orelse nonEmpty(tmp) orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/{s}discord-ipc-{d}", .{ base, subdir, n });
}

/// Where Discord parks the socket relative to the base dir: directly in it
/// for a regular install, or inside the app's own runtime subdirectory for
/// sandboxed Flatpak/Snap installs (both remap the socket rather than
/// exposing it at the top level, so a plain discord-ipc-N scan misses them).
pub const socket_subdirs = [_][]const u8{ "", "app/com.discordapp.Discord/", "snap.discord/" };

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
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (w + 2 > buf.len) break;
        switch (s[i]) {
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
                buf[w] = s[i];
                w += 1;
            },
        }
    }
    // On truncation, never leave a split multi-byte UTF-8 sequence at the
    // end — invalid UTF-8 inside the JSON gets the whole SET_ACTIVITY
    // silently rejected. If the first unprocessed byte is a continuation
    // byte we stopped mid-codepoint: drop the partial codepoint's
    // already-written bytes (bytes >= 0x80 always map 1:1 through the else
    // arm, so input distance equals output distance).
    if (i < s.len and s[i] & 0xC0 == 0x80) {
        var j = i;
        while (j > 0 and s[j] & 0xC0 == 0x80) j -= 1;
        w -= @min(w, i - j);
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
    // 256 so URLs never truncate: base_buf/cover_url_buf are [256]u8, and a
    // cut-off details_url/large_url is a broken link. Overlong title/artist
    // text merely truncates for display, which is acceptable.
    var esc: [4][256]u8 = undefined;
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
/// A size cap for one buildActivityRequestJson output, sized to cover the
/// actual worst case: four escaped fields at up to 256 bytes each (the esc
/// buffers' cap), the client_id at up to 32 escaped bytes (~48 with its
/// scaffolding), plus the JSON scaffolding and two i64s (~120 bytes) is
/// ~1200; 1344 leaves headroom. model.zig sizes its buffers (the persisted
/// signature field and its two scratch buffers) off this one constant
/// rather than picking three separate numbers that would all just need to
/// agree anyway. main.zig's stdin read limit and encodeActivityFrame's
/// body buffer (both 2048) must stay comfortably larger than this.
pub const activity_request_max = 1344;

pub const ActivityRequest = struct {
    /// The Discord application ID to handshake with. Empty = fall back to
    /// the build-time `client_id` constant (the helper's safety net; the
    /// model always sends its effective ID). Deliberately part of the
    /// request/signature string: editing the ID in the sheet must respawn
    /// the helper under the new identity.
    client_id: []const u8 = "",
    details: []const u8 = "",
    state: []const u8 = "",
    url: []const u8 = "",
    cover_url: []const u8 = "",
    duration_s: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub fn buildActivityRequestJson(buf: []u8, req: ActivityRequest, include_elapsed: bool) ![]const u8 {
    var esc: [4][256]u8 = undefined; // matches buildActivityJson's cap — see the note there
    var id_esc: [32]u8 = undefined; // a real snowflake is <= 20 digits

    var w = std.Io.Writer.fixed(buf);
    try w.print("{{", .{});
    // Omitted (not emitted empty) when unset so the build-time-ID flow's
    // wire format — and the exact-string tests that pin it — stay unchanged.
    if (req.client_id.len > 0) try w.print("\"client_id\":\"{s}\",", .{jsonEscape(&id_esc, req.client_id)});
    try w.print("\"details\":\"{s}\",\"state\":\"{s}\",\"url\":\"{s}\",\"cover_url\":\"{s}\",\"duration_s\":{d}", .{
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
    try testing.expectEqualStrings("/run/user/1000/discord-ipc-0", try resolveSocketPath(&buf, "/run/user/1000", "/should/not/win", null, "", 0));
    try testing.expectEqualStrings("/tmp/xyz/discord-ipc-0", try resolveSocketPath(&buf, null, "/tmp/xyz", null, "", 0));
    try testing.expectEqualStrings("/tmp/discord-ipc-0", try resolveSocketPath(&buf, null, null, null, "", 0));
    try testing.expectEqualStrings("/tmp/discord-ipc-0", try resolveSocketPath(&buf, "", "", "", "", 0));
}

test "resolveSocketPath covers sandboxed installs and higher socket indices" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/run/user/1000/app/com.discordapp.Discord/discord-ipc-3",
        try resolveSocketPath(&buf, "/run/user/1000", null, null, socket_subdirs[1], 3),
    );
    try testing.expectEqualStrings(
        "/run/user/1000/snap.discord/discord-ipc-9",
        try resolveSocketPath(&buf, "/run/user/1000", null, null, socket_subdirs[2], 9),
    );
}

test "jsonEscape truncation never splits a multi-byte UTF-8 sequence" {
    var buf: [2048]u8 = undefined;
    // 200 two-byte codepoints = 400 bytes, well past the 256-byte escape
    // cap; the cut must land on a codepoint boundary or Discord rejects
    // the whole payload as invalid JSON.
    const long = "é" ** 200;
    const out = try buildActivityRequestJson(&buf, .{ .details = long }, false);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "activity_request_max covers worst-case field lengths" {
    var buf: [activity_request_max]u8 = undefined;
    const long = "x" ** 300; // past the escape cap in every field at once
    _ = try buildActivityRequestJson(&buf, .{
        .client_id = long,
        .details = long,
        .state = long,
        .url = long,
        .cover_url = long,
        .duration_s = std.math.maxInt(i64),
        .elapsed_ms = std.math.minInt(i64),
    }, true);
}

test "isValidClientId accepts 17-20 digit snowflakes only" {
    try testing.expect(isValidClientId("12345678901234567")); // 17
    try testing.expect(isValidClientId("12345678901234567890")); // 20
    try testing.expect(!isValidClientId("1234567890123456")); // 16
    try testing.expect(!isValidClientId("123456789012345678901")); // 21
    try testing.expect(!isValidClientId("12345678901234567x"));
    try testing.expect(!isValidClientId(""));
    try testing.expect(!isValidClientId("123456789012345 78"));
}

test "buildActivityRequestJson carries client_id only when set" {
    var buf: [512]u8 = undefined;
    const with_id = try buildActivityRequestJson(&buf, .{ .client_id = "123456789012345678", .details = "Night Drive" }, false);
    try testing.expect(std.mem.startsWith(u8, with_id, "{\"client_id\":\"123456789012345678\","));

    const without = try buildActivityRequestJson(&buf, .{ .details = "Night Drive" }, false);
    try testing.expect(std.mem.indexOf(u8, without, "client_id") == null);
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
