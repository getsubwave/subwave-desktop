//! Deterministic reconnect and buffering-watchdog policy.
const std = @import("std");
const protocol = @import("station_protocol.zig");

pub const buffering_watchdog_ms: u64 = 6_000;
pub const max_attempt: u8 = 9;

pub const Platform = enum { linux, macos, windows, other };

pub const TimerKey = struct {
    generation: u64,
    load_id: u64,
    timer_id: u64,
};

pub const Cancelled = struct {
    retry_timer_id: ?u64 = null,
    watchdog_timer_id: ?u64 = null,
};

pub const FailureContext = struct {
    reconnect_allowed: bool,
    platform: Platform,
    format: protocol.StreamFormat,
};

pub const Retry = struct {
    timer: TimerKey,
    delay_ms: u64,
    attempt: u8,
    fallback_to_mp3: bool,
    cancel_watchdog_timer_id: ?u64,
};

pub const Policy = struct {
    generation: u64,
    load_id: u64,
    attempt: u8 = 0,
    retry_timer: ?TimerKey = null,
    watchdog_timer: ?TimerKey = null,

    pub fn init(generation: u64, load_id: u64) Policy {
        return .{ .generation = generation, .load_id = load_id };
    }

    /// Install a replacement/reconnect load while retaining its failure run.
    /// The returned timer IDs belong to the old load and should be cancelled.
    pub fn replaceLoad(self: *Policy, generation: u64, load_id: u64) Cancelled {
        const cancelled = self.takeTimers();
        self.generation = generation;
        self.load_id = load_id;
        return cancelled;
    }

    /// Schedule one retry for a matching failed load. Callers own timer IDs.
    /// Pause, stop, and disconnect pass reconnect_allowed=false and receive no
    /// new work; cancel() should also be applied to already armed timers.
    pub fn failed(self: *Policy, failed_load: struct { generation: u64, load_id: u64 }, timer_id: u64, context: FailureContext) !?Retry {
        if (failed_load.generation != self.generation or failed_load.load_id != self.load_id) return null;
        if (!context.reconnect_allowed) return null;
        if (timer_id == 0 or self.retry_timer != null) return error.InvalidTimer;
        if (self.attempt < max_attempt) self.attempt += 1;
        const timer: TimerKey = .{ .generation = self.generation, .load_id = self.load_id, .timer_id = timer_id };
        self.retry_timer = timer;
        const cancel_watchdog_timer_id = if (self.watchdog_timer) |watchdog| watchdog.timer_id else null;
        self.watchdog_timer = null;
        return .{
            .timer = timer,
            .delay_ms = delayForAttempt(self.attempt),
            .attempt = self.attempt,
            .fallback_to_mp3 = context.platform == .linux and context.format != .mp3 and self.attempt == 3,
            .cancel_watchdog_timer_id = cancel_watchdog_timer_id,
        };
    }

    /// Consume only the exact currently armed timer. A stale station/load or
    /// superseded timer can never request a new audio load.
    pub fn retryFired(self: *Policy, timer: TimerKey) bool {
        const expected = self.retry_timer orelse return false;
        if (!sameTimer(expected, timer)) return false;
        self.retry_timer = null;
        return true;
    }

    /// Starts/restarts the six-second watchdog for this exact load.
    pub fn armWatchdog(self: *Policy, timer_id: u64) !struct { timer: TimerKey, delay_ms: u64, cancel_timer_id: ?u64 } {
        if (timer_id == 0) return error.InvalidTimer;
        const previous = if (self.watchdog_timer) |timer| timer.timer_id else null;
        const timer: TimerKey = .{ .generation = self.generation, .load_id = self.load_id, .timer_id = timer_id };
        self.watchdog_timer = timer;
        return .{ .timer = timer, .delay_ms = buffering_watchdog_ms, .cancel_timer_id = previous };
    }

    pub fn watchdogFired(self: *Policy, timer: TimerKey) bool {
        const expected = self.watchdog_timer orelse return false;
        if (!sameTimer(expected, timer)) return false;
        self.watchdog_timer = null;
        return true;
    }

    /// Confirmed healthy playback alone clears the failure run.
    pub fn healthy(self: *Policy) Cancelled {
        const cancelled = self.takeTimers();
        self.attempt = 0;
        return cancelled;
    }

    /// Manual pause/stop/disconnect cancels all pending recovery work.
    pub fn cancel(self: *Policy) Cancelled {
        const cancelled = self.takeTimers();
        self.attempt = 0;
        return cancelled;
    }

    fn takeTimers(self: *Policy) Cancelled {
        const result: Cancelled = .{
            .retry_timer_id = if (self.retry_timer) |timer| timer.timer_id else null,
            .watchdog_timer_id = if (self.watchdog_timer) |timer| timer.timer_id else null,
        };
        self.retry_timer = null;
        self.watchdog_timer = null;
        return result;
    }
};

pub fn delayForAttempt(attempt: u8) u64 {
    if (attempt == 0) return 0;
    const shift: u6 = @intCast(@min(attempt - 1, 7));
    return @min(@as(u64, 500) << shift, 60_000);
}

fn sameTimer(a: TimerKey, b: TimerKey) bool {
    return a.generation == b.generation and a.load_id == b.load_id and a.timer_id == b.timer_id;
}

test "retry delay doubles from 500 milliseconds and caps at 60 seconds" {
    const expected = [_]u64{ 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000 };
    for (expected, 1..) |delay, attempt| try std.testing.expectEqual(delay, delayForAttempt(@intCast(attempt)));
    try std.testing.expectEqual(@as(u64, 60_000), delayForAttempt(40));
}

test "retry timers require full generation load and timer identity" {
    var policy = Policy.init(7, 41);
    const retry = (try policy.failed(.{ .generation = 7, .load_id = 41 }, 101, .{ .reconnect_allowed = true, .platform = .macos, .format = .mp3 })).?;
    try std.testing.expectEqual(@as(u64, 500), retry.delay_ms);
    try std.testing.expect(!policy.retryFired(.{ .generation = 6, .load_id = 41, .timer_id = 101 }));
    try std.testing.expect(!policy.retryFired(.{ .generation = 7, .load_id = 40, .timer_id = 101 }));
    try std.testing.expect(!policy.retryFired(.{ .generation = 7, .load_id = 41, .timer_id = 102 }));
    try std.testing.expect(policy.retryFired(retry.timer));
    try std.testing.expect(!policy.retryFired(retry.timer));
}

test "pause stop policy and old load failures schedule no recovery" {
    var policy = Policy.init(1, 42);
    try std.testing.expect((try policy.failed(.{ .generation = 1, .load_id = 41 }, 1, .{ .reconnect_allowed = true, .platform = .linux, .format = .opus })) == null);
    try std.testing.expect((try policy.failed(.{ .generation = 1, .load_id = 42 }, 1, .{ .reconnect_allowed = false, .platform = .linux, .format = .opus })) == null);
    try std.testing.expectEqual(@as(u8, 0), policy.attempt);
}

test "Linux optional format falls back exactly on attempt three" {
    var policy = Policy.init(1, 41);
    for (1..5) |attempt| {
        const retry = (try policy.failed(.{ .generation = 1, .load_id = 41 }, @intCast(100 + attempt), .{ .reconnect_allowed = true, .platform = .linux, .format = .flac })).?;
        try std.testing.expectEqual(attempt == 3, retry.fallback_to_mp3);
        try std.testing.expect(policy.retryFired(retry.timer));
    }
    var mac = Policy.init(1, 41);
    for (1..4) |attempt| {
        const retry = (try mac.failed(.{ .generation = 1, .load_id = 41 }, @intCast(200 + attempt), .{ .reconnect_allowed = true, .platform = .macos, .format = .aac })).?;
        try std.testing.expect(!retry.fallback_to_mp3);
        _ = mac.retryFired(retry.timer);
    }
}

test "healthy reset cancel and replacement invalidate timers" {
    var policy = Policy.init(2, 41);
    const watchdog = try policy.armWatchdog(302);
    try std.testing.expectEqual(@as(u64, buffering_watchdog_ms), watchdog.delay_ms);
    const retry = (try policy.failed(.{ .generation = 2, .load_id = 41 }, 301, .{ .reconnect_allowed = true, .platform = .linux, .format = .mp3 })).?;
    try std.testing.expectEqual(@as(?u64, 302), retry.cancel_watchdog_timer_id);
    _ = try policy.armWatchdog(302);
    const cancelled = policy.healthy();
    try std.testing.expectEqual(@as(?u64, 301), cancelled.retry_timer_id);
    try std.testing.expectEqual(@as(?u64, 302), cancelled.watchdog_timer_id);
    try std.testing.expectEqual(@as(u8, 0), policy.attempt);
    try std.testing.expect(!policy.retryFired(retry.timer));
    try std.testing.expect(!policy.watchdogFired(watchdog.timer));

    _ = try policy.armWatchdog(303);
    const replaced = policy.replaceLoad(3, 42);
    try std.testing.expectEqual(@as(?u64, 303), replaced.watchdog_timer_id);
    try std.testing.expect(!policy.watchdogFired(.{ .generation = 2, .load_id = 41, .timer_id = 303 }));
    try std.testing.expectEqual(@as(u64, 3), policy.generation);
    try std.testing.expectEqual(@as(u64, 42), policy.load_id);
}

test "watchdog restart and firing are exact and six seconds" {
    var policy = Policy.init(9, 77);
    const first = try policy.armWatchdog(401);
    const second = try policy.armWatchdog(402);
    try std.testing.expectEqual(@as(?u64, 401), second.cancel_timer_id);
    try std.testing.expectEqual(@as(u64, 6_000), second.delay_ms);
    try std.testing.expect(!policy.watchdogFired(first.timer));
    try std.testing.expect(policy.watchdogFired(second.timer));
}
