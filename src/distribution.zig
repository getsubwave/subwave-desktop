//! Which channel this build ships through, and what that channel allows.
//!
//! The SDK's build graph passes no app-level `-D` options through to src/, so
//! the channel is a checked-in constant that scripts/set-distribution.sh
//! rewrites in a store workflow before it builds — the same move
//! set-close-policy.sh makes on app.zon. Keep the `channel` declaration on one
//! line in exactly this shape; the script asserts on it.
//!
//! The checked-in value is `.github`, and scripts/check-release-flags.sh fails
//! CI if it is ever committed as anything else: a store build that leaked into
//! the GitHub releases would silently stop telling those listeners about new
//! versions.
const std = @import("std");
const builtin = @import("builtin");

pub const Channel = enum { github, store };

pub const channel: Channel = .github;

/// GitHub builds poll Releases and show an update notice. Store builds
/// (Microsoft Store, Snap Store, Mac App Store) are updated by the store, and
/// an in-app route to outside downloads is a review rejection there.
pub fn checksForUpdates(c: Channel) bool {
    return c == .github;
}

/// The Ko-fi tip link leaves the Mac App Store build only: Apple routes tips to
/// a developer through in-app purchase. The Microsoft Store and the Snap Store
/// allow the link.
pub fn offersSupportLink(c: Channel, os: std.Target.Os.Tag) bool {
    return !(c == .store and os == .macos);
}

pub const checks_for_updates = checksForUpdates(channel);
pub const offers_support_link = offersSupportLink(channel, builtin.os.tag);

const testing = std.testing;

test "only GitHub builds check for updates" {
    try testing.expect(checksForUpdates(.github));
    try testing.expect(!checksForUpdates(.store));
}

test "the support link leaves the Mac App Store build and nothing else" {
    for ([_]std.Target.Os.Tag{ .macos, .windows, .linux }) |os| {
        try testing.expect(offersSupportLink(.github, os));
    }
    try testing.expect(!offersSupportLink(.store, .macos));
    try testing.expect(offersSupportLink(.store, .windows));
    try testing.expect(offersSupportLink(.store, .linux));
}
