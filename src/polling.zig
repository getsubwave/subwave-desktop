//! Polling policy, independent of response handling and timer effects.
const std = @import("std");

pub const Cadence = struct {
    now_playing_ms: u32 = 0,
    state_session_ms: u32 = 0,
    themes_ms: u32 = 0,
    signal_ms: u32 = 0,
};

pub fn cadence(player: bool, active: bool, tuned: bool, playing: bool, probe_slow: bool) Cadence {
    if (!player or (!active and !tuned)) return .{};
    if (!active) return .{ .now_playing_ms = 10_000, .state_session_ms = 30_000 };
    return .{
        .now_playing_ms = 5000,
        .state_session_ms = 5000,
        .themes_ms = 30_000,
        .signal_ms = if (playing) (if (probe_slow) @as(u32, 15_000) else 5000) else 0,
    };
}

test "foreground cadence, including probe backoff and paused or tuned-out audio" {
    const t = std.testing;
    try t.expectEqual(Cadence{ .now_playing_ms = 5000, .state_session_ms = 5000, .themes_ms = 30_000, .signal_ms = 5000 }, cadence(true, true, true, true, false));
    try t.expectEqual(@as(u32, 15_000), cadence(true, true, true, true, true).signal_ms);
    try t.expectEqual(@as(u32, 0), cadence(true, true, true, false, false).signal_ms);
    try t.expectEqual(@as(u32, 5000), cadence(true, true, false, false, false).now_playing_ms);
}

test "background track freshness stays within ten seconds and other feeds slow" {
    const expected: Cadence = .{ .now_playing_ms = 10_000, .state_session_ms = 30_000 };
    try std.testing.expectEqual(expected, cadence(true, false, true, true, false));
    try std.testing.expectEqual(expected, cadence(true, false, true, false, true));
    try std.testing.expectEqual(Cadence{}, cadence(true, false, false, false, false));
    try std.testing.expectEqual(Cadence{}, cadence(false, true, true, true, false));
}
