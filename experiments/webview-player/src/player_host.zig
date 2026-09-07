const protocol = @import("protocol.zig");
const native_sdk = @import("native_sdk");
const std = @import("std");

pub const PlayerHost = struct {
    playback: protocol.Playback = .stopped,
    volume: f32 = 1,
    revision: u64 = 0,
    generation: u64 = 1,
    loaded: bool = false,
    play_after_load: bool = false,
    ignore_until_next_load: bool = false,
    error_store: [256]u8 = undefined,
    error_len: usize = 0,
    load_count: u64 = 0,
    play_count: u64 = 0,
    spectrum_received: u64 = 0,

    pub fn snapshot(self: *const PlayerHost) protocol.Snapshot {
        return .{
            .revision = self.revision,
            .generation = self.generation,
            .playback = self.playback,
            .volume = self.volume,
            .error_message = if (self.error_len > 0) self.error_store[0..self.error_len] else null,
        };
    }

    pub fn apply(self: *PlayerHost, services: native_sdk.platform.PlatformServices, command: protocol.Command, stream_url: []const u8) !void {
        switch (command) {
            .play => {
                if (!self.loaded) {
                    if (self.playback == .loading) return;
                    _ = try services.audioLoadUrl(stream_url, "", 0);
                    self.clearError();
                    self.ignore_until_next_load = false;
                    self.load_count += 1;
                    self.play_after_load = true;
                    self.setPlayback(.loading);
                } else if (self.playback != .playing) {
                    try services.audioPlay();
                    self.clearError();
                    self.play_count += 1;
                    self.setPlayback(.playing);
                }
            },
            .pause => if (self.playback == .loading) {
                self.play_after_load = false;
                self.setPlayback(.paused);
            } else if (self.loaded and self.playback == .playing) {
                try services.audioPause();
                self.setPlayback(.paused);
            },
            .stop => {
                try services.audioStop();
                self.loaded = false;
                self.play_after_load = false;
                self.ignore_until_next_load = true;
                self.generation += 1;
                self.setPlayback(.stopped);
            },
            .volume => |value| {
                try services.audioSetVolume(value);
                if (self.volume != value) {
                    self.volume = value;
                    self.revision += 1;
                }
            },
        }
    }

    pub fn onAudio(self: *PlayerHost, services: native_sdk.platform.PlatformServices, event: native_sdk.platform.AudioEvent) !bool {
        if (self.ignore_until_next_load) return false;
        switch (event.kind) {
            .loaded => {
                self.loaded = true;
                if (self.play_after_load) {
                    try services.audioPlay();
                    self.play_count += 1;
                    self.play_after_load = false;
                    self.setPlayback(.playing);
                }
                return true;
            },
            .position => {
                self.setPlayback(if (event.playing) .playing else .paused);
                return true;
            },
            .completed => {
                self.loaded = false;
                self.setPlayback(.stopped);
                return true;
            },
            .failed => {
                self.loaded = false;
                self.play_after_load = false;
                self.setError("native audio playback failed");
                return true;
            },
            .spectrum => {
                return false;
            },
        }
    }

    pub fn acceptSpectrum(self: *PlayerHost) bool {
        if (self.ignore_until_next_load or !self.loaded or self.playback != .playing) return false;
        self.spectrum_received += 1;
        return true;
    }

    fn setPlayback(self: *PlayerHost, value: protocol.Playback) void {
        if (self.playback == value) return;
        self.playback = value;
        self.revision += 1;
    }

    fn clearError(self: *PlayerHost) void {
        if (self.error_len == 0) return;
        self.error_len = 0;
        self.revision += 1;
    }

    fn setError(self: *PlayerHost, message: []const u8) void {
        self.error_len = @min(message.len, self.error_store.len);
        @memcpy(self.error_store[0..self.error_len], message[0..self.error_len]);
        self.setPlayback(.@"error");
    }
};

const FakeAudio = struct {
    loads: u64 = 0,
    plays: u64 = 0,
    pauses: u64 = 0,
    stops: u64 = 0,
    volume: f32 = 1,
    fail_load: bool = false,

    fn services(self: *FakeAudio) native_sdk.platform.PlatformServices {
        return .{
            .context = self,
            .audio_load_url_fn = load,
            .audio_play_fn = play,
            .audio_pause_fn = pause,
            .audio_stop_fn = stop,
            .audio_set_volume_fn = setVolume,
        };
    }
    fn load(context: ?*anyopaque, url: []const u8, cache: []const u8, expected: u64) anyerror!native_sdk.platform.AudioLoadResolution {
        _ = url;
        _ = cache;
        _ = expected;
        const self: *FakeAudio = @ptrCast(@alignCast(context.?));
        if (self.fail_load) return error.FakeLoadFailed;
        self.loads += 1;
        return .stream;
    }
    fn play(context: ?*anyopaque) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context.?));
        self.plays += 1;
    }
    fn pause(context: ?*anyopaque) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context.?));
        self.pauses += 1;
    }
    fn stop(context: ?*anyopaque) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context.?));
        self.stops += 1;
    }
    fn setVolume(context: ?*anyopaque, value: f32) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context.?));
        self.volume = value;
    }
};

test "one load across repeated play and pause resume does not reload" {
    var fake: FakeAudio = .{};
    var host: PlayerHost = .{};
    try host.apply(fake.services(), .play, "http://127.0.0.1:1/stream.mp3");
    try host.apply(fake.services(), .play, "http://127.0.0.1:1/stream.mp3");
    try std.testing.expectEqual(@as(u64, 1), fake.loads);
    try std.testing.expectEqual(protocol.Playback.loading, host.playback);
    _ = try host.onAudio(fake.services(), .{ .kind = .loaded });
    try std.testing.expectEqual(@as(u64, 1), fake.plays);
    try host.apply(fake.services(), .pause, "");
    try host.apply(fake.services(), .play, "");
    try std.testing.expectEqual(@as(u64, 1), fake.loads);
    try std.testing.expectEqual(@as(u64, 2), fake.plays);
}

test "pause during load cancels autoplay and stop ignores late events" {
    var fake: FakeAudio = .{};
    var host: PlayerHost = .{};
    try host.apply(fake.services(), .play, "http://127.0.0.1:1/stream.mp3");
    try host.apply(fake.services(), .pause, "");
    _ = try host.onAudio(fake.services(), .{ .kind = .loaded });
    try std.testing.expectEqual(@as(u64, 0), fake.plays);
    try host.apply(fake.services(), .stop, "");
    _ = try host.onAudio(fake.services(), .{ .kind = .loaded });
    _ = try host.onAudio(fake.services(), .{ .kind = .position, .playing = true });
    try std.testing.expect(!host.acceptSpectrum());
    try std.testing.expectEqual(protocol.Playback.stopped, host.playback);
}

test "synchronous load failure leaves the prior error coherent" {
    var fake: FakeAudio = .{ .fail_load = true };
    var host: PlayerHost = .{};
    host.setError("previous failure");
    const before = host.snapshot();
    try std.testing.expectError(error.FakeLoadFailed, host.apply(fake.services(), .play, "http://127.0.0.1:1/stream.mp3"));
    const after = host.snapshot();
    try std.testing.expectEqual(before.revision, after.revision);
    try std.testing.expectEqual(protocol.Playback.@"error", after.playback);
    try std.testing.expectEqualStrings("previous failure", after.error_message.?);
}

test "audio failure owns the error transition" {
    var fake: FakeAudio = .{};
    var host: PlayerHost = .{};
    try host.apply(fake.services(), .play, "http://127.0.0.1:1/stream.mp3");
    _ = try host.onAudio(fake.services(), .{ .kind = .failed });
    try std.testing.expectEqual(protocol.Playback.@"error", host.playback);
    try std.testing.expect(host.snapshot().error_message != null);
}
