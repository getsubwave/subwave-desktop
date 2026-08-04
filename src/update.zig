//! Self-update phase 1: version compare + GitHub release endpoints.
//!
//! `version` is the compiled-in app version. app.zon cannot be imported from
//! src/ (outside the module path), so this constant is the runtime authority;
//! scripts/make-release.sh refuses to cut a release when the two drift.
const std = @import("std");
const links = @import("links.zig");

pub const version = "0.8.1";

pub const release_api_url = "https://api.github.com/repos/getsubwave/subwave-desktop/releases/latest";
/// The static releases/latest page always shows the newest build, so the
/// Model never stores a per-release URL — see `links.zig` for the opener.
pub const release_page_url = links.release_page;

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

// The interesting cases for isNewer sit right next to whatever `version`
// happens to be, so derive them from it rather than writing the neighbours in
// by hand. Literal neighbours silently stop testing what they name at the next
// bump: "v0.7.1" was the one-patch-newer case until 0.8.0 made it older, which
// failed CI, and "v0.7.0" was the equal case until the same bump quietly turned
// it into a second older case.
const current = parseTag(version).?;
fn verTag(comptime major: u32, comptime minor: u32, comptime patch: u32) []const u8 {
    return std.fmt.comptimePrint("v{d}.{d}.{d}", .{ major, minor, patch });
}

test "isNewer: newer on any component, with or without the v" {
    try testing.expect(isNewer("v99.0.0"));
    try testing.expect(isNewer("99.0.0"));
    try testing.expect(isNewer(verTag(current.major + 1, current.minor, current.patch)));
    try testing.expect(isNewer(verTag(current.major, current.minor + 1, current.patch)));
    try testing.expect(isNewer(verTag(current.major, current.minor, current.patch + 1)));
    // No leading v, one patch up — the bare-tag path past the neighbour math.
    try testing.expect(isNewer(verTag(current.major, current.minor, current.patch + 1)[1..]));
}

test "isNewer: equal and older stay quiet" {
    try testing.expect(!isNewer(version));
    try testing.expect(!isNewer(verTag(current.major, current.minor, current.patch)));
    try testing.expect(!isNewer("v0.0.1"));
    if (current.minor > 0) try testing.expect(!isNewer(verTag(current.major, current.minor - 1, 9)));
    if (current.patch > 0) try testing.expect(!isNewer(verTag(current.major, current.minor, current.patch - 1)));
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
