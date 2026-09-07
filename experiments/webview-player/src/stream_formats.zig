//! Ported from repository src/stream_format.zig at b2ffb98.
//! Native decoder support is intersected with the station advertisement.
const std = @import("std");
const protocol = @import("station_protocol.zig");
const decoders = @import("station_decoders.zig");
pub const Format = protocol.StreamFormat;

pub fn platformSupports(os: std.Target.Os.Tag, format: Format) bool {
    if (format == .mp3) return true;
    return switch (os) {
        .linux => true,
        .macos, .windows => format == .aac,
        else => false,
    };
}
pub fn available(os: std.Target.Os.Tag, format: Format, flags: ?decoders.StreamFlags) bool {
    if (format == .mp3) return true;
    if (!platformSupports(os, format)) return false;
    const advertised = flags orelse return false;
    return switch (format) {
        .mp3 => true,
        .aac => advertised.aac,
        .opus => advertised.opus,
        .flac => advertised.flac,
    };
}
pub fn mount(format: Format) []const u8 {
    return switch (format) {
        .mp3 => "/stream.mp3",
        .aac => "/stream.aac",
        .opus => "/stream.opus",
        .flac => "/stream.flac",
    };
}

test "every platform intersects optional formats with station flags" {
    const all: decoders.StreamFlags = .{ .aac = true, .opus = true, .flac = true };
    for ([_]std.Target.Os.Tag{ .linux, .macos, .windows, .freestanding }) |os| {
        try std.testing.expect(available(os, .mp3, null));
        for ([_]Format{ .aac, .opus, .flac }) |format| {
            try std.testing.expect(!available(os, format, null));
            try std.testing.expectEqual(platformSupports(os, format), available(os, format, all));
        }
    }
    try std.testing.expect(!available(.windows, .opus, all));
    try std.testing.expect(!available(.macos, .flac, all));
    try std.testing.expect(available(.linux, .flac, all));
    try std.testing.expect(!available(.linux, .aac, .{}));
}
