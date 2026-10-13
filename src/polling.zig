//! Polling policy, independent of response handling and timer effects.
const std = @import("std");

pub const Cadence = struct {
    /// The joined now-playing + state pair the listener hold resolves from.
    now_playing_ms: u32 = 0,
    session_ms: u32 = 0,
    themes_ms: u32 = 0,
    signal_ms: u32 = 0,
};

/// What the cadence depends on, named so the call site reads plainly.
pub const State = struct {
    /// The player is up (not onboarding).
    player: bool = false,
    /// Main is focused, unoccluded and not swapped out for the mini player.
    active: bool = false,
    /// A stream is loaded, playing or paused.
    tuned: bool = false,
    /// Audio is actually running.
    playing: bool = false,
    /// The signal probe is in its failure backoff.
    probe_slow: bool = false,
};

pub fn cadence(s: State) Cadence {
    if (!s.player or (!s.active and !s.tuned)) return .{};
    if (!s.active) return .{ .now_playing_ms = 10_000, .session_ms = 30_000 };
    return .{
        .now_playing_ms = 5000,
        .session_ms = 5000,
        .themes_ms = 30_000,
        .signal_ms = if (s.playing) (if (s.probe_slow) @as(u32, 15_000) else 5000) else 0,
    };
}

test "foreground cadence, including probe backoff and paused or tuned-out audio" {
    const t = std.testing;
    const playing: State = .{ .player = true, .active = true, .tuned = true, .playing = true };
    try t.expectEqual(Cadence{ .now_playing_ms = 5000, .session_ms = 5000, .themes_ms = 30_000, .signal_ms = 5000 }, cadence(playing));
    var backoff = playing;
    backoff.probe_slow = true;
    try t.expectEqual(@as(u32, 15_000), cadence(backoff).signal_ms);
    try t.expectEqual(@as(u32, 0), cadence(.{ .player = true, .active = true, .tuned = true }).signal_ms);
    try t.expectEqual(@as(u32, 5000), cadence(.{ .player = true, .active = true }).now_playing_ms);
}

test "background track freshness stays within ten seconds and other feeds slow" {
    const expected: Cadence = .{ .now_playing_ms = 10_000, .session_ms = 30_000 };
    try std.testing.expectEqual(expected, cadence(.{ .player = true, .tuned = true, .playing = true }));
    try std.testing.expectEqual(expected, cadence(.{ .player = true, .tuned = true, .probe_slow = true }));
    try std.testing.expectEqual(Cadence{}, cadence(.{ .player = true }));
    try std.testing.expectEqual(Cadence{}, cadence(.{ .active = true, .tuned = true, .playing = true }));
}
