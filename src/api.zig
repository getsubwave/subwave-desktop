//! Station endpoint URLs. Runtime base (so the station is switchable at
//! runtime) — every builder writes into a caller buffer. The one authority on
//! the API shape (mirrors app/src/lib/api.ts in the subwave monorepo).

const std = @import("std");

pub const default_base = "https://www.getsubwave.com";

fn build(buf: []u8, base: []const u8, path: []const u8) ![]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(buf, "{s}{s}", .{ b, path });
}

pub fn streamUrl(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/stream.mp3");
}
pub fn nowPlaying(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/now-playing");
}
pub fn state(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/state");
}
pub fn themes(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/themes");
}
pub fn session(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/session");
}
pub fn schedule(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/schedule");
}
pub fn request(buf: []u8, base: []const u8) ![]const u8 {
    return build(buf, base, "/api/request");
}

pub fn coverUrl(buf: []u8, base: []const u8, id: []const u8) ![]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(buf, "{s}/api/cover/{s}", .{ b, id });
}
pub fn requestStatus(buf: []u8, base: []const u8, id: []const u8) ![]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(buf, "{s}/api/request/{s}", .{ b, id });
}

// Normalize an operator-entered station address into a base URL: trim spaces,
// default to https:// when no scheme, drop any trailing slash. Writes into buf.
pub fn normalizeBase(buf: []u8, raw: []const u8) ![]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    s = std.mem.trimEnd(u8, s, "/");
    if (s.len == 0) return error.EmptyBase;
    const has_scheme = std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
    if (has_scheme) return std.fmt.bufPrint(buf, "{s}", .{s});
    return std.fmt.bufPrint(buf, "https://{s}", .{s});
}

const testing = std.testing;

test "normalizeBase defaults the scheme and drops trailing slashes" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("https://radio.example", try normalizeBase(&buf, "  radio.example/ "));
    try testing.expectEqualStrings("http://localhost:3000", try normalizeBase(&buf, "http://localhost:3000/"));
    try testing.expectError(error.EmptyBase, normalizeBase(&buf, "  / "));
}

test "url builders join base and path" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("https://x.test/stream.mp3", try streamUrl(&buf, "https://x.test/"));
    try testing.expectEqualStrings("https://x.test/api/cover/ab12", try coverUrl(&buf, "https://x.test", "ab12"));
}
