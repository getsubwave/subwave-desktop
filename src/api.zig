//! Station endpoint URLs. Pure string building — the one authority on the API
//! shape (mirrors app/src/lib/api.ts in the subwave monorepo). The base is a
//! compile-time default for now; Phase 7 makes it runtime-configurable.

const std = @import("std");

pub const default_base = "https://www.getsubwave.com";

// Comptime URL builders for the fixed endpoints — no allocation, embedded in
// the binary. Runtime-base variants land in Phase 7.
pub fn streamUrl(comptime base: []const u8) []const u8 {
    return base ++ "/stream.mp3";
}
pub fn nowPlaying(comptime base: []const u8) []const u8 {
    return base ++ "/api/now-playing";
}
pub fn state(comptime base: []const u8) []const u8 {
    return base ++ "/api/state";
}
pub fn themes(comptime base: []const u8) []const u8 {
    return base ++ "/api/themes";
}
pub fn session(comptime base: []const u8) []const u8 {
    return base ++ "/api/session";
}
pub fn schedule(comptime base: []const u8) []const u8 {
    return base ++ "/api/schedule";
}
pub fn request(comptime base: []const u8) []const u8 {
    return base ++ "/api/request";
}

// Runtime cover URL into `buf`: <base>/api/cover/<id>. The proxy already
// returns a compact 300x300 JPEG (~10 KB), within the 256 KiB fetch cap and
// the 512x512 image-registry decode limit.
pub fn coverUrl(buf: []u8, comptime base: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, base ++ "/api/cover/{s}", .{id});
}

// Runtime request-status URL into `buf`: <base>/api/request/<id>.
pub fn requestStatus(buf: []u8, comptime base: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, base ++ "/api/request/{s}", .{id});
}
