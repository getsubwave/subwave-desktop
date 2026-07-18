//! Listener-selectable stream format. The station always serves the MP3
//! floor; Opus / FLAC / AAC are optional mounts the operator enables per
//! station (they ride the `stream` flags on /api/now-playing). Which of them
//! a listener can pick is ALSO a platform question: the macOS host plays
//! everything through one AVPlayer, which cannot demux the Ogg container, so
//! the Ogg-encapsulated mounts (Opus, FLAC) are Linux/GStreamer-only; AAC
//! (ADTS) and MP3 decode on both. Mirrors app/src/lib/streamFormat.ts in the
//! subwave monorepo.

const std = @import("std");
const builtin = @import("builtin");

pub const StreamFormat = enum {
    mp3,
    aac,
    opus,
    flac,

    /// Display order: universal floor first, then rising fidelity/cost.
    pub const all = [_]StreamFormat{ .mp3, .aac, .opus, .flac };

    /// Icecast mount path — matches the Liquidsoap outputs and the Caddy
    /// route table (/stream.mp3, /stream.opus, …).
    pub fn mount(self: StreamFormat) []const u8 {
        return switch (self) {
            .mp3 => "/stream.mp3",
            .aac => "/stream.aac",
            .opus => "/stream.opus",
            .flac => "/stream.flac",
        };
    }

    /// The settings.json value and the pick_format markup payload.
    pub fn id(self: StreamFormat) []const u8 {
        return @tagName(self);
    }

    pub fn label(self: StreamFormat) []const u8 {
        return switch (self) {
            .mp3 => "MP3",
            .aac => "AAC",
            .opus => "Opus",
            .flac => "FLAC",
        };
    }

    pub fn detail(self: StreamFormat) []const u8 {
        return switch (self) {
            .mp3 => "universal · most reliable",
            .aac => "efficient · easy on data",
            .opus => "best quality per bit",
            .flac => "lossless · heavy on data",
        };
    }
};

/// null for anything that isn't a known format id — callers keep their
/// MP3 default.
pub fn fromId(v: []const u8) ?StreamFormat {
    return std.meta.stringToEnum(StreamFormat, v);
}

/// Can THIS host's player engine decode the format? GStreamer (Linux)
/// demuxes Ogg — offered optimistically, since decode support is whatever
/// plugins are installed (the reconnect loop drops to the floor when a mount
/// won't actually play). AVPlayer (macOS) has no Ogg demuxer, which rules
/// out the Ogg-encapsulated Opus and FLAC mounts. Anything else (defensive)
/// gets the MP3 floor only.
pub fn platformSupports(format: StreamFormat) bool {
    if (format == .mp3) return true;
    return switch (builtin.os.tag) {
        .linux => true,
        .macos => format == .aac,
        else => false,
    };
}

const testing = std.testing;

test "mounts follow the /stream.<fmt> route table and ids round-trip" {
    inline for (StreamFormat.all) |f| {
        try testing.expect(std.mem.startsWith(u8, f.mount(), "/stream."));
        try testing.expectEqual(f, fromId(f.id()).?);
    }
    try testing.expectEqualStrings("/stream.opus", StreamFormat.opus.mount());
    try testing.expectEqual(@as(?StreamFormat, null), fromId("wav"));
}

test "the MP3 floor plays everywhere" {
    try testing.expect(platformSupports(.mp3));
    // Ogg-encapsulated mounts never outrank the platform gate.
    if (builtin.os.tag == .macos) {
        try testing.expect(platformSupports(.aac));
        try testing.expect(!platformSupports(.opus));
        try testing.expect(!platformSupports(.flac));
    }
}
