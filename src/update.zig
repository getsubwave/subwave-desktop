//! Self-update phase 1: version compare + GitHub release endpoints.
//!
//! `version` is the compiled-in app version. app.zon cannot be imported from
//! src/ (outside the module path), so this constant is the runtime authority;
//! scripts/make-release.sh refuses to cut a release when the two drift.
const std = @import("std");
const builtin = @import("builtin");

pub const version = "0.7.0";

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
    try testing.expect(isNewer("v0.7.1"));
}

test "isNewer: equal and older stay quiet" {
    try testing.expect(!isNewer("v0.7.0"));
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
