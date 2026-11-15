//! Native station/session integration. This host owns HTTP, decoder lifetime,
//! retry timers and retained feed arenas independently of any WebView.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("native_sdk");
const protocol = @import("station_protocol.zig");
const selection_mod = @import("station_selection.zig");
const session_mod = @import("session.zig");
const reconnect = @import("reconnect.zig");
const effects_mod = @import("host_effects.zig");
const audio_mod = @import("audio_owner.zig");
const decoders = @import("station_decoders.zig");
const formats = @import("stream_formats.zig");
const vault = @import("credential_vault.zig");
const station_client = @import("station_client.zig");

pub const poll_timer_id: u64 = 0x1000_0000;
const PollRequest = struct { key: session_mod.PollKey, tag: effects_mod.RequestTag };

pub const Host = struct {
    allocator: std.mem.Allocator,
    basic: ?vault.BasicRecord = null,
    listener: ?vault.ListenerRecord = null,
    allow_insecure_http: bool = false,
    http: effects_mod.Owner,
    audio: audio_mod.Owner,
    selection: selection_mod.Coordinator = .{},
    session: session_mod.Session = .{},
    recovery: reconnect.Policy = reconnect.Policy.init(0, 0),
    polls: [5]?PollRequest = @splat(null),
    feeds: [7]?decoders.Decoded = @splat(null),
    volume: f64 = 0.8,
    muted: bool = false,
    format: protocol.StreamFormat = .mp3,
    flags: ?decoders.StreamFlags = null,
    buffering: bool = false,
    connection: protocol.Connection = .none,
    error_code: ?[]const u8 = null,
    revision: u64 = 1,
    retry_due_ms: u64 = 0,
    next_watchdog_id: u64 = 0x1000_0000_0000,
    spectrum: [32]u8 = @splat(0),
    spectrum_sequence: u64 = 0,
    format_dirty: bool = false,
    track_store: [4][128]u8 = undefined,
    track_lens: [4]usize = @splat(0),
    has_track: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Host {
        return .{ .allocator = allocator, .http = try effects_mod.Owner.init(allocator), .audio = .{ .allocator = allocator } };
    }
    pub fn bind(self: *Host, runtime: *sdk.Runtime) !void {
        self.http.bind(runtime);
        try runtime.options.platform.services.startTimer(poll_timer_id, std.time.ns_per_s, true);
    }
    pub fn stop(self: *Host, services: sdk.platform.PlatformServices) void {
        services.cancelTimer(poll_timer_id) catch {};
        self.cancelRecovery(services);
        self.audio.stop(services) catch {};
        self.http.stop();
        self.clearFeeds();
    }
    pub fn deinit(self: *Host) void {
        std.debug.assert(self.audio.relay == null);
        self.clearFeeds();
        self.http.deinit();
        self.clearCredentials();
    }

    /// Public candidate only. Task4 attaches vault lookup/validation before
    /// this health gate; no UI credential submission is accepted here yet.
    pub fn connectPublic(self: *Host, address: []const u8) !u64 {
        const candidate = try self.selection.begin(address);
        errdefer _ = self.selection.cancel(candidate.operation_id) catch {};
        const tag = try self.http.request(&candidate.station, candidate.operation_id, candidate.generation, .health, .{}, null);
        try self.selection.attachRequest(candidate.operation_id, tag);
        self.connection = .checking;
        self.revision += 1;
        return candidate.operation_id;
    }
    pub fn cancelConnect(self: *Host, operation_id: u64) !void {
        _ = try self.selection.cancel(operation_id);
        self.http.cancelOperation(operation_id);
        self.connection = if (self.selection.active_station != null) .ready else .none;
        self.revision += 1;
    }

    pub fn disconnect(self: *Host, services: sdk.platform.PlatformServices, now_ms: u64) !void {
        if (self.selection.candidate) |candidate| try self.cancelConnect(candidate.operation_id);
        self.http.cancelGeneration(self.session.generation);
        self.cancelRecovery(services);
        try self.execute(services, self.session.disconnect(), now_ms);
        self.selection.active_station = null;
        self.clearCredentials();
        self.polls = @splat(null);
        self.clearFeeds();
        self.flags = null;
        self.format = .mp3;
        self.buffering = false;
        self.connection = .none;
        self.error_code = null;
        self.revision += 1;
    }

    pub fn command(self: *Host, services: sdk.platform.PlatformServices, value: protocol.PlaybackCommand, now_ms: u64) !void {
        switch (value) {
            .volume => |v| {
                if (!std.math.isFinite(v) or v < 0 or v > 1) return error.InvalidVolume;
                try services.audioSetVolume(@floatCast(if (self.muted) 0 else v));
                if (self.volume == v) return;
                self.volume = v;
            },
            .mute => |muted| {
                try services.audioSetVolume(@floatCast(if (muted) 0 else self.volume));
                if (self.muted == muted) return;
                self.muted = muted;
            },
            .format => |format| {
                if (!formats.available(builtin.os.tag, format, self.flags)) return error.UnsupportedFormat;
                if (self.format == format) return;
                self.format = format;
                self.format_dirty = true;
                const old_intent = self.session.intent;
                self.cancelRecovery(services);
                try self.execute(services, self.session.apply(.stopped), now_ms);
                try self.execute(services, self.session.apply(old_intent), now_ms);
            },
            .play, .pause, .stop => {
                if (value == .play and self.selection.active_station == null) return error.NoStation;
                if (value == .play and self.session.intent == .playing and
                    (self.session.playback == .loading or self.session.playback == .playing)) return;
                self.cancelRecovery(services);
                const desired: protocol.Intent = switch (value) {
                    .play => .playing,
                    .pause => .paused,
                    else => .stopped,
                };
                try self.execute(services, self.session.apply(desired), now_ms);
                if (desired != .playing) self.buffering = false;
            },
        }
        self.revision += 1;
    }

    pub const Interceptor = struct {
        context: *anyopaque,
        consume: *const fn (*anyopaque, *effects_mod.Completion) anyerror!bool,
    };
    pub fn drain(self: *Host, services: sdk.platform.PlatformServices, now_ms: u64) !void {
        return self.drainIntercept(services, now_ms, null);
    }
    pub fn drainIntercept(self: *Host, services: sdk.platform.PlatformServices, now_ms: u64, interceptor: ?Interceptor) !void {
        var boundary = self.http.boundary();
        while (self.http.next(&boundary)) |value| {
            var completion = value;
            defer completion.deinit();
            if (interceptor) |hook| if (try hook.consume(hook.context, &completion)) continue;
            if (completion.tag.kind == .health) {
                const outcome: selection_mod.HealthOutcome = if (completion.result == .data and completion.result.data.payload.health.isHealthy()) .healthy else .{ .failed = if (completion.result == .failure and completion.result.failure == .auth_required) .@"auth-required" else .health_failed };
                switch (self.selection.resolve(completion.tag, outcome)) {
                    .stale => {},
                    .failed => {
                        self.connection = if (self.selection.active_station != null) .ready else if (outcome.failed == .@"auth-required") .@"auth-required" else .@"error";
                        self.revision += 1;
                    },
                    .activated => |activation| {
                        self.clearCredentials();
                        try self.activate(services, activation, now_ms);
                    },
                }
                continue;
            }
            var poll: ?PollRequest = null;
            for (&self.polls) |*slot| if (slot.*) |request| {
                if (std.meta.eql(request.tag, completion.tag)) {
                    poll = request;
                    slot.* = null;
                    break;
                }
            };
            const request = poll orelse continue;
            if (request.key.generation != self.session.generation) continue;
            if (completion.result == .data and completion.tag.kind == .now_playing and completion.result.data.payload.now_playing.stream_online != null) {
                const online = completion.result.data.payload.now_playing.stream_online.?;
                try self.execute(services, self.session.onStreamOnline(request.key, online, now_ms), now_ms);
                if (online and self.connection == .offline) {
                    self.connection = .ready;
                    self.revision += 1;
                }
            } else if (!self.session.onPollComplete(request.key, now_ms)) continue;
            if (completion.result == .data) {
                const index = @intFromEnum(completion.tag.kind);
                if (self.feeds[index]) |*old| old.deinit();
                self.feeds[index] = completion.result.data;
                completion.result = .{ .failure = .cancelled }; // ownership transferred
                if (completion.tag.kind == .now_playing) {
                    const now = self.feeds[index].?.payload.now_playing;
                    self.flags = if (now.stream) |flags| .{ .aac = flags.aac, .opus = flags.opus, .flac = flags.flac } else null;
                    self.projectTrack(now.track);
                }
                self.revision += 1;
            }
        }
    }

    pub fn activate(self: *Host, services: sdk.platform.PlatformServices, activation: selection_mod.Activation, now_ms: u64) !void {
        return self.activateWithFormat(services, activation, .mp3, now_ms);
    }
    pub fn activateWithFormat(self: *Host, services: sdk.platform.PlatformServices, activation: selection_mod.Activation, format: protocol.StreamFormat, now_ms: u64) !void {
        self.http.cancelGeneration(activation.old_generation);
        self.cancelRecovery(services);
        self.polls = @splat(null);
        self.clearFeeds();
        self.flags = null;
        self.format = if (formats.platformSupports(builtin.os.tag, format)) format else .mp3;
        self.format_dirty = false;
        self.connection = .ready;
        self.error_code = null;
        self.recovery = reconnect.Policy.init(activation.new_generation, 0);
        // Selection and remote credential validation have already committed.
        // A device failure is playback state for that selected station; it
        // must not relabel the confirmed credential transaction as failed.
        self.execute(services, self.session.activate(activation.new_generation, now_ms, true), now_ms) catch
            self.transportUnavailable(services, "audio_activation_failed");
        self.execute(services, self.session.pollDue(now_ms), now_ms) catch
            self.transportUnavailable(services, "station_effects_failed");
        self.revision += 1;
    }
    pub fn clearCredentials(self: *Host) void {
        if (self.basic) |*value| value.deinit();
        if (self.listener) |*value| value.deinit();
        self.basic = null;
        self.listener = null;
        self.allow_insecure_http = false;
    }
    fn apiAuth(self: *Host, output: []u8) !station_client.Auth {
        return .{ .authorization = if (self.basic) |*value| try vault.writeAuthorization(value, output) else null, .allow_insecure_http = self.allow_insecure_http };
    }

    pub fn onAudio(self: *Host, services: sdk.platform.PlatformServices, event: sdk.platform.AudioEvent, now_ms: u64) !void {
        if (event.load_id == 0 or self.session.load_id != event.load_id) return;
        const previous_playback = self.session.playback;
        const previous_buffering = self.buffering;
        const previous_error = self.error_code;
        if (event.kind == .position and self.session.intent == .playing) {
            self.buffering = event.buffering;
            if (event.buffering) {
                if (self.recovery.watchdog_timer == null) {
                    const timer = try self.recovery.armWatchdog(self.next_watchdog_id);
                    self.next_watchdog_id += 1;
                    services.startTimer(timer.timer.timer_id, timer.delay_ms * std.time.ns_per_ms, false) catch {
                        self.transportUnavailable(services, "timer_unavailable");
                        return;
                    };
                }
            } else if (event.playing) {
                self.cancelTimers(services, self.recovery.healthy());
                try self.execute(services, self.session.healthyPlayback(), now_ms);
                self.error_code = null;
            }
        }
        const kind: session_mod.AudioEvent = switch (event.kind) {
            .loaded => .loaded,
            .failed, .completed => .failed,
            .position => .position,
            .spectrum => .spectrum,
        };
        const actions = self.session.onAudio(self.session.generation, event.load_id, kind);
        if (event.kind == .failed or event.kind == .completed) {
            self.audio.stop(services) catch {};
            if (self.session.intent != .playing) self.cancelRecovery(services);
        }
        if (event.kind == .spectrum and self.session.intent == .playing and self.session.playback == .playing) {
            self.spectrum = event.bands;
            self.spectrum_sequence += 1;
        }
        try self.execute(services, actions, now_ms);
        if (previous_playback != self.session.playback or previous_buffering != self.buffering or (previous_error != null) != (self.error_code != null)) self.revision += 1;
    }

    pub fn onTimer(self: *Host, services: sdk.platform.PlatformServices, id: u64, now_ms: u64) !void {
        if (id == poll_timer_id) {
            if (self.selection.active_station != null) try self.execute(services, self.session.pollDue(now_ms), now_ms);
            return;
        }
        if (self.session.retry) |key| if (key.timer_id == id) {
            if (!self.recovery.retryFired(.{ .generation = key.generation, .load_id = key.load_id, .timer_id = key.timer_id })) return;
            try self.execute(services, self.session.onRetryTimer(key), now_ms);
            self.revision += 1;
            return;
        };
        if (self.recovery.watchdog_timer) |timer| if (timer.timer_id == id and self.recovery.watchdogFired(timer)) {
            try self.execute(services, self.session.onAudio(timer.generation, timer.load_id, .failed), now_ms);
            self.revision += 1;
        };
    }

    fn execute(self: *Host, services: sdk.platform.PlatformServices, actions: session_mod.Actions, now_ms: u64) anyerror!void {
        for (actions.slice()) |action| switch (action) {
            .load => |load_id| {
                self.cancelTimers(services, self.recovery.replaceLoad(self.session.generation, load_id));
                self.spectrum = @splat(0);
                self.buffering = false;
                var url: [8192]u8 = undefined;
                defer std.crypto.secureZero(u8, &url);
                var authorization: [1024]u8 = undefined;
                defer std.crypto.secureZero(u8, &authorization);
                const auth = try self.apiAuth(&authorization);
                const station = &(self.selection.active_station orelse return error.NoStation);
                var base_url = try std.fmt.bufPrint(&url, "{s}{s}", .{ station.base(), formats.mount(self.format) });
                if ((self.basic != null or self.listener != null) and std.mem.startsWith(u8, station.base(), "http://") and !self.allow_insecure_http) return error.InsecureCredentials;
                if (self.listener) |*value| {
                    url[base_url.len] = '?';
                    const query = try vault.writeListenerQuery(value, url[base_url.len + 1 ..]);
                    base_url = url[0 .. base_url.len + 1 + query.len];
                }
                self.audio.load(services, load_id, .{ .upstream_url = base_url, .authorization = auth.authorization }) catch {
                    try self.execute(services, self.session.onAudio(self.session.generation, load_id, .failed), now_ms);
                    continue;
                };
                try services.audioSetVolume(@floatCast(if (self.muted) 0 else self.volume));
            },
            .unload => {
                try self.audio.stop(services);
                self.spectrum = @splat(0);
                self.buffering = false;
            },
            .play => {
                self.audio.play(services) catch {
                    if (self.session.load_id) |id| try self.execute(services, self.session.onAudio(self.session.generation, id, .failed), now_ms);
                };
            },
            .pause => self.audio.pause(services) catch self.transportUnavailable(services, "audio_pause_failed"),
            .retry_needed => |failed_id| {
                self.audio.stop(services) catch {};
                self.buffering = false;
                self.error_code = "audio_failed";
                try self.execute(services, self.session.scheduleRetry(self.session.nextRetryKey(failed_id) orelse return error.IdentityExhausted, reconnect.delayForAttempt(self.recovery.attempt +| 1)), now_ms);
            },
            .schedule_retry => |retry| {
                const decision = (try self.recovery.failed(.{ .generation = retry.key.generation, .load_id = retry.key.load_id }, retry.key.timer_id, .{ .reconnect_allowed = self.session.intent == .playing, .platform = switch (builtin.os.tag) {
                    .linux => .linux,
                    .macos => .macos,
                    .windows => .windows,
                    else => .other,
                }, .format = self.format })) orelse continue;
                if (decision.cancel_watchdog_timer_id) |id| services.cancelTimer(id) catch {};
                if (decision.fallback_to_mp3) {
                    self.format = .mp3;
                    self.format_dirty = true;
                }
                self.retry_due_ms = now_ms + decision.delay_ms;
                services.startTimer(retry.key.timer_id, decision.delay_ms * std.time.ns_per_ms, false) catch {
                    self.transportUnavailable(services, "timer_unavailable");
                };
            },
            .cancel_retry => |timer| services.cancelTimer(timer.timer_id) catch {},
            .poll => |key| {
                const station = &(self.selection.active_station orelse continue);
                var authorization: [1024]u8 = undefined;
                defer std.crypto.secureZero(u8, &authorization);
                const auth = try self.apiAuth(&authorization);
                const tag = self.http.request(station, 0, key.generation, key.endpoint, auth, null) catch {
                    _ = self.session.onPollComplete(key, now_ms);
                    continue;
                };
                for (&self.polls) |*slot| if (slot.* == null) {
                    slot.* = .{ .key = key, .tag = tag };
                    break;
                };
            },
            .cancel_poll => |key| self.http.cancelGeneration(key.generation),
            .station_offline => {
                self.connection = .offline;
                if (self.session.load_id) |id| try self.execute(services, self.session.onAudio(self.session.generation, id, .failed), now_ms);
            },
            .spectrum, .position => {},
            .identity_exhausted => return error.IdentityExhausted,
        };
    }

    fn transportUnavailable(self: *Host, services: sdk.platform.PlatformServices, code: []const u8) void {
        self.cancelRecovery(services);
        self.session.retry = null;
        self.session.load_id = null;
        self.session.intent = .stopped;
        self.session.playback = .@"error";
        self.audio.stop(services) catch {};
        self.buffering = false;
        self.error_code = code;
        self.revision += 1;
    }
    fn cancelTimers(_: *Host, services: sdk.platform.PlatformServices, cancelled: reconnect.Cancelled) void {
        if (cancelled.retry_timer_id) |id| services.cancelTimer(id) catch {};
        if (cancelled.watchdog_timer_id) |id| services.cancelTimer(id) catch {};
    }
    fn cancelRecovery(self: *Host, services: sdk.platform.PlatformServices) void {
        self.cancelTimers(services, self.recovery.cancel());
    }
    fn clearFeeds(self: *Host) void {
        for (&self.feeds) |*feed| {
            if (feed.*) |*value| value.deinit();
            feed.* = null;
        }
        self.has_track = false;
        self.track_lens = @splat(0);
    }
    fn projectTrack(self: *Host, maybe: ?decoders.Track) void {
        self.has_track = false;
        const track = maybe orelse return;
        // Identity is never shortened. Display fields may end at a UTF-8 boundary.
        const id = track.source_id orelse "";
        if (id.len > 128) return;
        const fields = [_][]const u8{ id, track.title orelse "", track.artist orelse "", track.album orelse "" };
        for (fields, 0..) |field, index| {
            var len = @min(field.len, 128);
            while (len < field.len and len > 0 and field[len] & 0xc0 == 0x80) len -= 1;
            @memcpy(self.track_store[index][0..len], field[0..len]);
            self.track_lens[index] = len;
        }
        self.has_track = true;
    }
    pub fn snapshot(self: *const Host, now_ms: u64) protocol.StationSnapshot {
        return .{
            .revision = self.revision,
            .generation = self.selection.generation,
            .playback = self.session.playback,
            .intent = self.session.intent,
            .buffering = self.buffering,
            .volume = self.volume,
            .muted = self.muted,
            .format = self.format,
            .connection = self.connection,
            .station = if (self.selection.active_station) |*station| .{ .id = &station.id, .base = station.base(), .name = "" } else null,
            .retry = if (self.session.retry != null) .{ .attempt = self.recovery.attempt, .dueInMs = self.retry_due_ms -| now_ms } else null,
            .track = if (self.has_track) .{ .id = self.track_store[0][0..self.track_lens[0]], .title = self.track_store[1][0..self.track_lens[1]], .artist = self.track_store[2][0..self.track_lens[2]], .album = self.track_store[3][0..self.track_lens[3]] } else null,
            .operations = .{ .station = self.selection.latest_station_operation },
            .@"error" = if (self.error_code) |code| .{ .code = code, .retryable = true } else null,
        };
    }
};

const Fake = struct {
    load_id: u64 = 0,
    loads: u64 = 0,
    plays: u64 = 0,
    fail_timer: bool = false,
    fail_volume: bool = false,
    fn services(self: *Fake) sdk.platform.PlatformServices {
        return .{ .context = self, .audio_load_request_fn = load, .audio_play_fn = play, .audio_pause_fn = nothing, .audio_stop_fn = nothing, .audio_set_volume_fn = volume, .start_timer_fn = timer, .cancel_timer_fn = cancel };
    }
    fn load(context: ?*anyopaque, request: sdk.platform.AudioUrlRequest) !sdk.platform.AudioLoadResolution {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.load_id = request.load_id;
        self.loads += 1;
        return .stream;
    }
    fn play(context: ?*anyopaque) !void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.plays += 1;
    }
    fn nothing(_: ?*anyopaque) !void {}
    fn volume(context: ?*anyopaque, _: f32) !void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.fail_volume) return error.AudioDeviceUnavailable;
    }
    fn timer(context: ?*anyopaque, _: u64, _: u64, _: bool) !void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.fail_timer) return error.TimerFailed;
    }
    fn cancel(_: ?*anyopaque, _: u64) !void {}
};
fn activateTest(host: *Host, services: sdk.platform.PlatformServices, address: []const u8, now: u64) !void {
    const op = try host.connectPublic(address);
    for (host.http.slots) |slot| if (slot != null and slot.?.tag.operation_id == op) {
        try host.http.effects.feedResponse(slot.?.tag.request_id, 200, "{\"status\":\"on-air\"}");
        break;
    };
    try host.drain(services, now);
}

test "host failed candidate preserves active audio and late load cannot drive replacement" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{};
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    const first = fake.load_id;
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = first }, 1);
    try std.testing.expectEqual(@as(u64, 1), fake.plays);
    const op = try host.connectPublic("http://127.0.0.1:43128");
    for (host.http.slots) |slot| if (slot != null and slot.?.tag.operation_id == op) {
        try host.http.effects.feedResponse(slot.?.tag.request_id, 503, "{}");
        break;
    };
    try host.drain(fake.services(), 2);
    try std.testing.expectEqual(@as(u64, 1), fake.loads);
    try std.testing.expectEqualStrings("http://127.0.0.1:43127", host.snapshot(2).station.?.base);
    try activateTest(&host, fake.services(), "http://127.0.0.1:43128", 3);
    const second = fake.load_id;
    try std.testing.expect(second != first);
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = first }, 4);
    try host.onAudio(fake.services(), .{ .kind = .spectrum, .load_id = first, .bands = @splat(255) }, 4);
    try std.testing.expectEqual(@as(u64, 1), fake.plays);
    try std.testing.expectEqual(@as(u64, 0), host.spectrum_sequence);
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = second }, 5);
    try std.testing.expectEqual(@as(u64, 2), fake.plays);
    var buffer: [protocol.max_snapshot_bytes]u8 = undefined;
    const encoded = try protocol.writeSnapshot(host.snapshot(5), &buffer);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "stream.mp3") == null);
}

test "confirmed station survives device activation failure and Play retries it" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{ .fail_volume = true };
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    const snapshot = host.snapshot(0);
    try std.testing.expectEqualStrings("http://127.0.0.1:43127", snapshot.station.?.base);
    try std.testing.expectEqual(protocol.OperationState.succeeded, snapshot.operations.station.?.status);
    try std.testing.expectEqual(protocol.Playback.@"error", snapshot.playback);
    try std.testing.expectEqual(protocol.Intent.stopped, snapshot.intent);
    try std.testing.expectEqualStrings("audio_activation_failed", snapshot.@"error".?.code);
    try std.testing.expect(host.audio.relay == null);
    fake.fail_volume = false;
    try host.command(fake.services(), .play, 1);
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = fake.load_id }, 2);
    try std.testing.expectEqual(protocol.Playback.playing, host.snapshot(2).playback);
}

test "host watchdog is not postponed by repeated buffering and pause cancels retry" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{};
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = fake.load_id }, 1);
    try host.onAudio(fake.services(), .{ .kind = .position, .load_id = fake.load_id, .playing = true, .buffering = true }, 2);
    const watchdog = host.recovery.watchdog_timer.?;
    const revision = host.revision;
    try host.onAudio(fake.services(), .{ .kind = .position, .load_id = fake.load_id, .playing = true, .buffering = true }, 1000);
    try std.testing.expectEqual(watchdog.timer_id, host.recovery.watchdog_timer.?.timer_id);
    try std.testing.expectEqual(revision, host.revision);
    try host.onTimer(fake.services(), watchdog.timer_id, 6002);
    const retry = host.session.retry.?;
    try std.testing.expectEqual(@as(u32, 1), host.snapshot(6002).retry.?.attempt);
    try std.testing.expectEqual(@as(u64, 500), host.snapshot(6002).retry.?.dueInMs);
    try host.command(fake.services(), .pause, 6200);
    try host.onTimer(fake.services(), retry.timer_id, 6502);
    try std.testing.expectEqual(@as(u64, 1), fake.loads);
    try std.testing.expectEqual(protocol.Intent.paused, host.session.intent);
    try std.testing.expect(host.session.retry == null and host.recovery.watchdog_timer == null);
}

test "timer admission failure leaves no phantom retry or watchdog" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{};
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    fake.fail_timer = true;
    try host.onAudio(fake.services(), .{ .kind = .failed, .load_id = fake.load_id }, 1);
    try std.testing.expect(host.session.retry == null and host.recovery.retry_timer == null);
    try std.testing.expect(host.audio.relay == null);
    try std.testing.expectEqualStrings("timer_unavailable", host.snapshot(1).@"error".?.code);
    fake.fail_timer = false;
    try host.command(fake.services(), .play, 2);
    try host.onAudio(fake.services(), .{ .kind = .loaded, .load_id = fake.load_id }, 3);
    fake.fail_timer = true;
    try host.onAudio(fake.services(), .{ .kind = .position, .load_id = fake.load_id, .playing = true, .buffering = true }, 4);
    try std.testing.expect(host.recovery.watchdog_timer == null and host.audio.relay == null);
}

test "four false station polls tear down and a true poll restores ready" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{};
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    for (0..5) |index| {
        const now: u64 = index * 5000;
        try host.onTimer(fake.services(), poll_timer_id, now);
        for (host.polls) |slot| if (slot != null and slot.?.key.endpoint == .now_playing) {
            try host.http.effects.feedResponse(slot.?.tag.request_id, 200, if (index < 4) "{\"streamOnline\":false}" else "{\"streamOnline\":true}");
            break;
        };
        try host.drain(fake.services(), now);
        if (index == 3) try std.testing.expectEqual(protocol.Connection.offline, host.connection);
    }
    try std.testing.expectEqual(protocol.Connection.ready, host.connection);
}

test "disconnect keeps bridge generation monotonic and invalidates pending candidates" {
    var host = try Host.init(std.testing.allocator);
    var fake: Fake = .{};
    defer host.deinit();
    defer host.stop(fake.services());
    host.http.effects.executor = .fake;
    try activateTest(&host, fake.services(), "http://127.0.0.1:43127", 0);
    const op = try host.connectPublic("http://127.0.0.1:43128");
    try host.disconnect(fake.services(), 1);
    try host.drain(fake.services(), 2);
    try std.testing.expectEqual(@as(u64, 1), host.snapshot(2).generation);
    try std.testing.expect(host.selection.active_station == null and host.selection.candidate == null);
    try std.testing.expectEqual(op, host.snapshot(2).operations.station.?.operationId);
    try std.testing.expectError(error.NoStation, host.command(fake.services(), .play, 2));
    try activateTest(&host, fake.services(), "http://127.0.0.1:43128", 3);
    try std.testing.expectEqual(@as(u64, 2), host.snapshot(3).generation);
}
