//! Outbound links and the per-OS default-browser opener.
//!
//! Every URL the app can hand to the desktop is baked in at comptime: the
//! Model never stores an opener URL, it only picks which argv to spawn. That
//! keeps the spawn surface a closed, auditable list — nothing the network
//! says can become a command line.
const std = @import("std");
const builtin = @import("builtin");

pub const release_page = "https://github.com/getsubwave/subwave-desktop/releases/latest";
pub const support = "https://ko-fi.com/pklair";

/// argv that hands `url` to whatever the desktop calls a browser.
pub fn openerArgv(comptime url: []const u8) []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        // The empty "" is `start`'s title argument; without it cmd treats a
        // quoted URL as the window title and opens nothing.
        .windows => &.{ "cmd", "/C", "start", "", url },
        else => &.{ "xdg-open", url },
    };
}

pub const open_release_argv = openerArgv(release_page);
pub const open_support_argv = openerArgv(support);

const testing = std.testing;

test "opener argv ends with the url on every host" {
    try testing.expectEqualStrings(release_page, open_release_argv[open_release_argv.len - 1]);
    try testing.expectEqualStrings(support, open_support_argv[open_support_argv.len - 1]);
}

test "opener argv names a launcher this OS actually has" {
    const expected: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "cmd",
        else => "xdg-open",
    };
    try testing.expectEqualStrings(expected, open_support_argv[0]);
    try testing.expect(open_support_argv.len >= 2);
}

test "links are https" {
    inline for (.{ release_page, support }) |u| {
        try testing.expect(std.mem.startsWith(u8, u, "https://"));
    }
}
