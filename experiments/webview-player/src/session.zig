//! Pure playback/session reducer. Native I/O is represented only as bounded actions.
const std = @import("std");
const protocol = @import("station_protocol.zig");
const decoders = @import("station_decoders.zig");

pub const max_actions: usize = 24;
pub const fast_poll_ms: u64 = 5_000;
pub const slow_poll_ms: u64 = 30_000;

pub const TimerKey = struct { generation: u64, load_id: u64, timer_id: u64 };
pub const PollKey = struct { generation: u64, request_id: u64, endpoint: decoders.Endpoint };
pub const AudioEvent = enum { loaded, failed, spectrum, position };

pub const Action = union(enum) {
    load: u64,
    unload: u64,
    play: u64,
    pause: u64,
    schedule_retry: struct { key: TimerKey, delay_ms: u64 },
    cancel_retry: TimerKey,
    retry_needed: u64,
    poll: PollKey,
    cancel_poll: PollKey,
    spectrum: u64,
    position: u64,
    station_offline,
    identity_exhausted,
};

pub const Actions = struct {
    items: [max_actions]Action = undefined,
    len: usize = 0,

    fn add(self: *Actions, action: Action) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = action;
        self.len += 1;
    }

    pub fn slice(self: *const Actions) []const Action {
        return self.items[0..self.len];
    }
};

const poll_endpoints = [_]decoders.Endpoint{ .now_playing, .state, .session, .themes, .schedule };
const PollSlot = struct { next_due_ms: u64 = 0, request: ?PollKey = null };

pub const Session = struct {
    generation: u64 = 0,
    intent: protocol.Intent = .stopped,
    playback: protocol.Playback = .stopped,
    load_id: ?u64 = null,
    failed_load_id: ?u64 = null,
    next_load_id: u64 = 1,
    next_timer_id: u64 = 1,
    next_request_id: u64 = 1,
    retry: ?TimerKey = null,
    polls: [poll_endpoints.len]PollSlot = @splat(.{}),
    offline_false_count: u8 = 0,
    offline_reported: bool = false,

    pub fn activate(self: *Session, generation: u64, now_ms: u64, autoplay: bool) Actions {
        var out: Actions = .{};
        if (generation == 0 or generation > protocol.max_operation_id) {
            out.add(.identity_exhausted);
            return out;
        }
        self.cancelOutstanding(&out);
        self.generation = generation;
        self.intent = if (autoplay) .playing else .stopped;
        self.playback = .stopped;
        self.load_id = null;
        self.failed_load_id = null;
        self.offline_false_count = 0;
        self.offline_reported = false;
        self.resetPolls(now_ms);
        if (autoplay) self.startLoad(&out);
        return out;
    }

    pub fn apply(self: *Session, desired: protocol.Intent) Actions {
        var out: Actions = .{};
        if (self.generation == 0) return out;
        switch (desired) {
            .playing => {
                self.intent = .playing;
                self.cancelRetry(&out);
                if (self.load_id) |id| {
                    if (self.playback == .paused) {
                        out.add(.{ .play = id });
                        self.playback = .playing;
                    }
                    // Repeated play while loading/playing is deliberately inert.
                } else self.startLoad(&out);
            },
            .paused => {
                self.intent = .paused;
                self.cancelRetry(&out);
                self.failed_load_id = null;
                if (self.load_id) |id| switch (self.playback) {
                    .loading => {
                        out.add(.{ .unload = id });
                        self.load_id = null;
                        self.playback = .paused;
                    },
                    .playing => {
                        out.add(.{ .pause = id });
                        self.playback = .paused;
                    },
                    else => {},
                };
                self.playback = .paused;
            },
            .stopped => {
                self.intent = .stopped;
                self.cancelRetry(&out);
                self.failed_load_id = null;
                if (self.load_id) |id| out.add(.{ .unload = id });
                self.load_id = null;
                self.playback = .stopped;
            },
        }
        return out;
    }

    pub fn onAudio(self: *Session, generation: u64, load_id: u64, event: AudioEvent) Actions {
        var out: Actions = .{};
        if (generation != self.generation or self.load_id != load_id) return out;
        switch (event) {
            .loaded => if (self.intent == .playing and self.playback == .loading) {
                self.playback = .playing;
                out.add(.{ .play = load_id });
            },
            .failed => {
                self.load_id = null;
                self.failed_load_id = load_id;
                self.playback = .@"error";
                if (self.intent == .playing) out.add(.{ .retry_needed = load_id });
            },
            .spectrum => if (self.playback == .playing) out.add(.{ .spectrum = load_id }),
            .position => if (self.playback == .playing) out.add(.{ .position = load_id }),
        }
        return out;
    }

    pub fn nextRetryKey(self: *Session, failed_load_id: u64) ?TimerKey {
        if (self.intent != .playing or self.load_id != null or self.failed_load_id != failed_load_id) return null;
        const timer_id = self.takeTimerId() orelse return null;
        return .{ .generation = self.generation, .load_id = failed_load_id, .timer_id = timer_id };
    }

    pub fn scheduleRetry(self: *Session, key: TimerKey, delay_ms: u64) Actions {
        var out: Actions = .{};
        if (self.intent != .playing or self.load_id != null or self.failed_load_id != key.load_id or key.generation != self.generation or key.timer_id == 0) return out;
        self.cancelRetry(&out);
        self.retry = key;
        out.add(.{ .schedule_retry = .{ .key = key, .delay_ms = delay_ms } });
        return out;
    }

    pub fn onRetryTimer(self: *Session, key: TimerKey) Actions {
        var out: Actions = .{};
        const expected = self.retry orelse return out;
        if (!std.meta.eql(expected, key) or key.generation != self.generation) return out;
        self.retry = null;
        if (self.intent == .playing and self.load_id == null) self.startLoad(&out);
        return out;
    }

    pub fn healthyPlayback(self: *Session) Actions {
        var out: Actions = .{};
        self.cancelRetry(&out);
        return out;
    }

    pub fn pollDue(self: *Session, now_ms: u64) Actions {
        var out: Actions = .{};
        if (self.generation == 0) return out;
        for (&self.polls, poll_endpoints) |*slot, endpoint| {
            if (slot.request != null or now_ms < slot.next_due_ms) continue;
            const request_id = self.takeRequestId() orelse {
                out.add(.identity_exhausted);
                break;
            };
            const key: PollKey = .{ .generation = self.generation, .request_id = request_id, .endpoint = endpoint };
            slot.request = key;
            out.add(.{ .poll = key });
        }
        return out;
    }

    pub fn disconnect(self: *Session) Actions {
        var out: Actions = .{};
        self.cancelOutstanding(&out);
        self.generation = 0;
        self.intent = .stopped;
        self.playback = .stopped;
        self.load_id = null;
        self.failed_load_id = null;
        self.offline_false_count = 0;
        self.offline_reported = false;
        return out;
    }

    pub fn onPollComplete(self: *Session, key: PollKey, now_ms: u64) bool {
        if (key.generation != self.generation) return false;
        const index = pollIndex(key.endpoint) orelse return false;
        const expected = self.polls[index].request orelse return false;
        if (!std.meta.eql(expected, key)) return false;
        self.polls[index].request = null;
        self.polls[index].next_due_ms = now_ms + pollInterval(key.endpoint);
        return true;
    }

    pub fn onStreamOnline(self: *Session, key: PollKey, online: bool, now_ms: u64) Actions {
        var out: Actions = .{};
        if (key.endpoint != .now_playing or !self.onPollComplete(key, now_ms)) return out;
        if (online) {
            self.offline_false_count = 0;
            self.offline_reported = false;
        } else if (!self.offline_reported) {
            self.offline_false_count +|= 1;
            if (self.offline_false_count >= 4) {
                self.offline_reported = true;
                out.add(.station_offline);
            }
        }
        return out;
    }

    fn startLoad(self: *Session, out: *Actions) void {
        const id = self.takeLoadId() orelse {
            out.add(.identity_exhausted);
            self.playback = .@"error";
            return;
        };
        self.load_id = id;
        self.failed_load_id = null;
        self.playback = .loading;
        out.add(.{ .load = id });
    }

    fn cancelOutstanding(self: *Session, out: *Actions) void {
        self.cancelRetry(out);
        if (self.load_id) |id| out.add(.{ .unload = id });
        for (&self.polls) |*slot| {
            if (slot.request) |key| out.add(.{ .cancel_poll = key });
            slot.* = .{};
        }
    }

    fn cancelRetry(self: *Session, out: *Actions) void {
        if (self.retry) |key| out.add(.{ .cancel_retry = key });
        self.retry = null;
    }

    fn resetPolls(self: *Session, now_ms: u64) void {
        for (&self.polls) |*slot| slot.* = .{ .next_due_ms = now_ms };
    }

    fn takeLoadId(self: *Session) ?u64 {
        const id = self.next_load_id;
        if (id == 0 or id > protocol.max_operation_id) return null;
        self.next_load_id += 1;
        return id;
    }
    fn takeTimerId(self: *Session) ?u64 {
        const id = self.next_timer_id;
        if (id == 0 or id > protocol.max_operation_id) return null;
        self.next_timer_id += 1;
        return id;
    }
    fn takeRequestId(self: *Session) ?u64 {
        const id = self.next_request_id;
        if (id == 0 or id > protocol.max_operation_id) return null;
        self.next_request_id += 1;
        return id;
    }
};

fn pollIndex(endpoint: decoders.Endpoint) ?usize {
    for (poll_endpoints, 0..) |candidate, i| if (candidate == endpoint) return i;
    return null;
}

fn pollInterval(endpoint: decoders.Endpoint) u64 {
    return switch (endpoint) {
        .now_playing, .state, .session => fast_poll_ms,
        .themes, .schedule => slow_poll_ms,
        else => unreachable,
    };
}

test "pause during load invalidates it while healthy pause resume keeps the stream" {
    var session: Session = .{};
    const started = session.activate(1, 0, true);
    const first = started.slice()[0].load;
    const paused_loading = session.apply(.paused);
    try std.testing.expectEqual(first, paused_loading.slice()[0].unload);
    try std.testing.expect(session.load_id == null);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(1, first, .loaded).len);

    const restarted = session.apply(.playing);
    const second = restarted.slice()[0].load;
    _ = session.onAudio(1, second, .loaded);
    const paused = session.apply(.paused);
    try std.testing.expectEqual(second, paused.slice()[0].pause);
    const resumed = session.apply(.playing);
    try std.testing.expectEqual(second, resumed.slice()[0].play);
    try std.testing.expectEqual(@as(usize, 0), session.apply(.playing).len);
}

test "failure retry uses a new load and stale audio and timer identities do nothing" {
    var session: Session = .{};
    const first = session.activate(7, 0, true).slice()[0].load;
    try std.testing.expectEqual(first, session.onAudio(7, first, .failed).slice()[0].retry_needed);
    const scheduled = session.scheduleRetry(session.nextRetryKey(first).?, 500);
    const timer = scheduled.slice()[0].schedule_retry.key;
    var stale = timer;
    stale.timer_id += 1;
    try std.testing.expectEqual(@as(usize, 0), session.onRetryTimer(stale).len);
    const second = session.onRetryTimer(timer).slice()[0].load;
    try std.testing.expect(second != first);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(7, first, .loaded).len);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(6, second, .failed).len);
}

test "pause and stop cancel retry and stale timer cannot reload" {
    var session: Session = .{};
    const load = session.activate(2, 0, true).slice()[0].load;
    _ = session.onAudio(2, load, .failed);
    const timer = session.scheduleRetry(session.nextRetryKey(load).?, 500).slice()[0].schedule_retry.key;
    try std.testing.expectEqual(timer, session.apply(.paused).slice()[0].cancel_retry);
    try std.testing.expectEqual(@as(usize, 0), session.onRetryTimer(timer).len);
    try std.testing.expectEqual(@as(usize, 0), session.apply(.stopped).len);
}

test "offline requires four consecutive false polls and true resets" {
    var session: Session = .{};
    _ = session.activate(3, 0, false);
    const stale = session.pollDue(0).slice()[0].poll;
    try std.testing.expectEqual(@as(usize, 0), session.onStreamOnline(stale, false, 1).len);
    var now: u64 = 1 + fast_poll_ms;
    for (0..2) |_| {
        const key = session.pollDue(now).slice()[0].poll;
        try std.testing.expectEqual(@as(usize, 0), session.onStreamOnline(key, false, now).len);
        now += fast_poll_ms;
    }
    var key = session.pollDue(now).slice()[0].poll;
    _ = session.onStreamOnline(key, true, now);
    now += fast_poll_ms;
    for (0..3) |_| {
        key = session.pollDue(now).slice()[0].poll;
        try std.testing.expectEqual(@as(usize, 0), session.onStreamOnline(key, false, now).len);
        now += fast_poll_ms;
    }
    key = session.pollDue(now).slice()[0].poll;
    try std.testing.expectEqual(Action.station_offline, session.onStreamOnline(key, false, now).slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), session.onStreamOnline(stale, true, now).len);
}

test "polls are independent nonoverlapping and switch cancels and resets them" {
    var session: Session = .{};
    _ = session.activate(10, 100, false);
    const initial = session.pollDue(100);
    try std.testing.expectEqual(@as(usize, 5), initial.len);
    try std.testing.expectEqual(@as(usize, 0), session.pollDue(40_000).len);
    const now_key = initial.slice()[0].poll;
    try std.testing.expect(session.onPollComplete(now_key, 200));
    try std.testing.expectEqual(@as(usize, 0), session.pollDue(5_199).len);
    try std.testing.expectEqual(decoders.Endpoint.now_playing, session.pollDue(5_200).slice()[0].poll.endpoint);

    const switched = session.activate(11, 9_000, false);
    // Four old requests remained in flight; the completed/reissued endpoint is fifth.
    try std.testing.expectEqual(@as(usize, 5), switched.len);
    try std.testing.expect(!session.onPollComplete(now_key, 9_001));
    try std.testing.expectEqual(@as(usize, 5), session.pollDue(9_000).len);
}

test "repeated loaded and paused visualization callbacks are inert" {
    var session: Session = .{};
    const load = session.activate(1, 0, true).slice()[0].load;
    try std.testing.expectEqual(load, session.onAudio(1, load, .loaded).slice()[0].play);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(1, load, .loaded).len);
    try std.testing.expectEqual(load, session.onAudio(1, load, .spectrum).slice()[0].spectrum);
    _ = session.apply(.paused);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(1, load, .spectrum).len);
    try std.testing.expectEqual(@as(usize, 0), session.onAudio(1, load, .position).len);
}

test "disconnect invalidates active work and generation zero cannot poll or play" {
    var session: Session = .{};
    _ = session.activate(4, 0, true);
    _ = session.pollDue(0);
    const actions = session.disconnect();
    try std.testing.expect(actions.len >= 6);
    try std.testing.expectEqual(@as(u64, 0), session.generation);
    try std.testing.expectEqual(@as(usize, 0), session.pollDue(99_000).len);
    try std.testing.expectEqual(@as(usize, 0), session.apply(.playing).len);
}

test "identity exhaustion reports a bounded action without wrapping" {
    var load_session: Session = .{ .next_load_id = protocol.max_operation_id + 1 };
    try std.testing.expectEqual(Action.identity_exhausted, load_session.activate(1, 0, true).slice()[0]);
    var request_session: Session = .{ .next_request_id = protocol.max_operation_id + 1 };
    _ = request_session.activate(1, 0, false);
    try std.testing.expectEqual(Action.identity_exhausted, request_session.pollDue(0).slice()[0]);
}
