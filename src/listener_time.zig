//! Listener-time projection of the station's live-edge track and booth feed.
const std = @import("std");

pub const max_session_turns = 120;
pub const max_hold_ms: i64 = 120_000;

pub fn Text(comptime capacity: usize) type {
    return struct {
        store: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), value: []const u8) void {
            var n = @min(value.len, capacity);
            if (n < value.len) while (n > 0 and value[n] & 0xc0 == 0x80) {
                n -= 1;
            };
            @memcpy(self.store[0..n], value[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.store[0..self.len];
        }
    };
}

pub fn bufferMs(seconds: ?f64, previous: i64) i64 {
    const value = seconds orelse return previous;
    if (!std.math.isFinite(value)) return previous;
    return @intFromFloat(std.math.clamp(value, 0, 60) * 1000);
}

pub const Track = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    song_id: []const u8 = "",
    musical_key: []const u8 = "",
    moods: []const u8 = "",
    energy: []const u8 = "",
    year: i64 = 0,
    duration_s: i64 = 0,
    bpm: i64 = 0,
    legacy_start_ms: ?i64 = null,
};

const OwnedTrack = struct {
    title: Text(512) = .{},
    artist: Text(256) = .{},
    album: Text(256) = .{},
    genre: Text(64) = .{},
    song_id: Text(64) = .{},
    musical_key: Text(16) = .{},
    moods: Text(96) = .{},
    energy: Text(16) = .{},
    year: i64 = 0,
    duration_s: i64 = 0,
    bpm: i64 = 0,
    legacy_start_ms: ?i64 = null,
    present: bool = false,

    fn set(self: *OwnedTrack, input: ?Track) void {
        self.present = input != null;
        const track = input orelse Track{};
        inline for (.{ "title", "artist", "album", "genre", "song_id", "musical_key", "moods", "energy" }) |field|
            @field(self, field).set(@field(track, field));
        self.year = track.year;
        self.duration_s = track.duration_s;
        self.bpm = track.bpm;
        self.legacy_start_ms = track.legacy_start_ms;
    }

    fn view(self: *const OwnedTrack) ?Track {
        if (!self.present) return null;
        return .{
            .title = self.title.slice(),
            .artist = self.artist.slice(),
            .album = self.album.slice(),
            .genre = self.genre.slice(),
            .song_id = self.song_id.slice(),
            .musical_key = self.musical_key.slice(),
            .moods = self.moods.slice(),
            .energy = self.energy.slice(),
            .year = self.year,
            .duration_s = self.duration_s,
            .bpm = self.bpm,
            .legacy_start_ms = self.legacy_start_ms,
        };
    }

    fn matches(self: *const OwnedTrack, input: ?Track) bool {
        if (self.present != (input != null)) return false;
        const track = input orelse return true;
        return std.mem.eql(u8, self.title.slice(), track.title) and std.mem.eql(u8, self.artist.slice(), track.artist);
    }
};

pub const Current = struct {
    title: []const u8,
    artist: []const u8 = "",
    song_id: []const u8 = "",
    started_at_ms: ?i64,
};

pub const Publication = struct {
    track: ?Track,
    audible_at_ms: ?i64,
    changed: bool,
    first: bool,
};

pub const Controller = struct {
    lead_ms: i64 = 0,
    audible_at_ms: ?i64 = null,
    clock_from_server: bool = false,
    live: OwnedTrack = .{},
    incoming: OwnedTrack = .{},
    incoming_known: bool = false,
    incoming_seen_ms: i64 = 0,
    resolved_start_ms: ?i64 = null,
    displayed_title: Text(512) = .{},
    displayed_artist: Text(256) = .{},
    displayed_present: bool = false,
    has_display: bool = false,
    live_known: bool = false,
    first_seen_ms: i64 = 0,
    dirty: bool = false,
    current_title: Text(512) = .{},
    current_artist: Text(256) = .{},
    current_song: Text(64) = .{},
    current_start_ms: ?i64 = null,
    current_dirty: bool = false,
    waiting_np: bool = false,
    waiting_state: bool = false,

    pub fn reset(self: *Controller) void {
        self.* = .{};
    }

    // One pair at a time: reusing an occupied SDK fetch key rejects the new
    // request, whose terminal would otherwise be mistaken for the old poll.
    pub fn beginPoll(self: *Controller) bool {
        if (self.waiting_np or self.waiting_state) return false;
        self.waiting_np = true;
        self.waiting_state = true;
        self.current_start_ms = null;
        return true;
    }

    pub fn receiveTrack(self: *Controller, track: ?Track, seconds: ?f64, now_ms: i64) void {
        self.waiting_np = false;
        self.lead_ms = bufferMs(seconds, self.lead_ms);
        if (!self.incoming_known or !self.incoming.matches(track)) self.incoming_seen_ms = now_ms;
        self.incoming.set(track);
        self.incoming_known = true;
    }

    pub fn failTrack(self: *Controller) void {
        self.waiting_np = false;
    }

    pub fn receiveCurrent(self: *Controller, current: ?Current) void {
        self.waiting_state = false;
        self.current_start_ms = null;
        if (current) |value| {
            self.current_title.set(value.title);
            self.current_artist.set(value.artist);
            self.current_song.set(value.song_id);
            self.current_start_ms = value.started_at_ms;
        }
        self.current_dirty = true;
    }

    pub fn advance(self: *Controller, now_ms: i64) ?Publication {
        if (!self.waiting_np and !self.waiting_state) {
            if (self.current_dirty) {
                self.dirty = true;
                self.current_dirty = false;
            }
            if (self.incoming_known) {
                if (!self.live_known or !self.live.matches(self.incoming.view())) {
                    self.first_seen_ms = self.incoming_seen_ms;
                    self.resolved_start_ms = null;
                }
                self.live = self.incoming;
                self.incoming_known = false;
                self.live_known = true;
                self.dirty = true;
            }
            if (self.current_start_ms) |start| {
                if (start <= now_ms and std.mem.eql(u8, self.current_title.slice(), self.live.title.slice()) and
                    (self.current_artist.len == 0 or std.mem.eql(u8, self.current_artist.slice(), self.live.artist.slice())) and
                    (self.current_song.len == 0 or self.live.song_id.len == 0 or std.mem.eql(u8, self.current_song.slice(), self.live.song_id.slice())))
                    self.resolved_start_ms = start;
            }
            if (self.resolved_start_ms == null) {
                if (self.live.legacy_start_ms) |start| {
                    if (start > 0 and start <= now_ms) self.resolved_start_ms = start;
                }
            }
        }
        if (!self.live_known) return null;
        const track = self.live.view();
        const same = self.has_display and self.displayed_present == self.live.present and
            std.mem.eql(u8, self.displayed_title.slice(), self.live.title.slice()) and
            std.mem.eql(u8, self.displayed_artist.slice(), self.live.artist.slice());
        // A resolved clock belongs to this identity. A later failed poll must
        // neither erase its hold nor stop its release while requests drain.
        const server_start = self.resolved_start_ms;
        const audible_at = if (track == null) null else if (server_start) |start| start +| self.lead_ms else self.first_seen_ms;
        if (!same and self.has_display and self.displayed_present and self.live.present and audible_at.? > now_ms) return null;
        var timing_changed = false;
        if (same) {
            if (server_start != null and audible_at != null and
                (self.audible_at_ms == null or @abs(audible_at.? -| self.audible_at_ms.?) > 2500))
            {
                self.audible_at_ms = audible_at;
                timing_changed = true;
            }
            if (!self.dirty and !timing_changed) return null;
        } else {
            self.audible_at_ms = audible_at;
            self.clock_from_server = server_start != null;
        }
        if (same and server_start != null) self.clock_from_server = true;
        const first = !self.has_display or !self.displayed_present;
        self.displayed_title.set(self.live.title.slice());
        self.displayed_artist.set(self.live.artist.slice());
        self.displayed_present = self.live.present;
        self.has_display = true;
        self.dirty = false;
        return .{ .track = track, .audible_at_ms = self.audible_at_ms, .changed = !same, .first = first };
    }
};

pub fn elapsedMs(now_ms: i64, audible_at_ms: i64, duration_ms: i64) i64 {
    const elapsed = @max(0, now_ms -| audible_at_ms);
    return if (duration_ms > 0) @min(elapsed, duration_ms) else elapsed;
}

// Controller stamps are ISO-8601, with optional fractional seconds and zone
// offsets. Reject invalid dates rather than parking a hold on a garbage stamp.
pub fn isoMs(value: []const u8) ?i64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;
    const year = digits(value[0..4]) orelse return null;
    const month = digits(value[5..7]) orelse return null;
    const day = digits(value[8..10]) orelse return null;
    const hour = digits(value[11..13]) orelse return null;
    const minute = digits(value[14..16]) orelse return null;
    const second = digits(value[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days = [_]i64{ 31, if (leap) @as(i64, 29) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > month_days[@intCast(month - 1)]) return null;
    var at: usize = 19;
    var fraction: i64 = 0;
    if (value[at] == '.') {
        at += 1;
        const begin = at;
        while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {
            if (at - begin < 3) fraction = fraction * 10 + value[at] - '0';
        }
        if (at == begin) return null;
        if (at - begin == 1) fraction *= 100;
        if (at - begin == 2) fraction *= 10;
    }
    if (at >= value.len) return null;
    var offset: i64 = 0;
    if (value[at] == 'Z' and at + 1 == value.len) {} else if ((value[at] == '+' or value[at] == '-') and at + 6 == value.len and value[at + 3] == ':') {
        const hours = digits(value[at + 1 .. at + 3]) orelse return null;
        const minutes = digits(value[at + 4 .. at + 6]) orelse return null;
        if (hours > 23 or minutes > 59) return null;
        offset = (hours * 60 + minutes) * 60;
        if (value[at] == '-') offset = -offset;
    } else return null;
    const adjusted_year = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(adjusted_year, 400);
    const yoe = adjusted_year - era * 400;
    const shifted_month = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * shifted_month + 2, 5) + day - 1;
    const days = era * 146097 + yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy - 719468;
    return (days * 86400 + hour * 3600 + minute * 60 + second - offset) * 1000 + fraction;
}

fn digits(value: []const u8) ?i64 {
    for (value) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

pub const TurnClass = enum { voice, dj, track, system };

pub fn turnClass(role: []const u8) TurnClass {
    if (std.mem.eql(u8, role, "segment")) return .voice;
    if (std.mem.eql(u8, role, "dj")) return .dj;
    if (std.mem.eql(u8, role, "track")) return .track;
    return .system;
}

pub fn isVoice(role: []const u8, kind: []const u8) bool {
    inline for (.{ "voice", "segment", "link", "intro", "station-id", "weather", "hourly", "say" }) |voice_kind|
        if (std.ascii.eqlIgnoreCase(kind, voice_kind)) return true;
    return std.ascii.eqlIgnoreCase(role, "voice") or std.ascii.eqlIgnoreCase(role, "segment");
}

pub fn speechMs(text: []const u8) i64 {
    var words: usize = 0;
    const view = std.unicode.Utf8View.init(text) catch return 3000;
    var iterator = view.iterator();
    var in_word = false;
    while (iterator.nextCodepoint()) |codepoint| {
        const whitespace = switch (codepoint) {
            0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
            else => false,
        };
        if (!whitespace and !in_word) words += 1;
        in_word = !whitespace;
    }
    return @intFromFloat(std.math.clamp(@round(@as(f64, @floatFromInt(words)) / 2.6 * 1000) + 1200, 3000, 45000));
}

pub fn lineMs(duration: ?f64, text: []const u8) i64 {
    if (duration) |value| {
        if (std.math.isFinite(value) and value > 0 and value <= 900_000) return @intFromFloat(@ceil(value));
    }
    return speechMs(text);
}

pub const Turn = struct {
    text: Text(1024) = .{},
    stamp: Text(64) = .{},
    persona: Text(128) = .{},
    track_id: Text(64) = .{},
    boundary_at: Text(64) = .{},
    boundary_name: Text(128) = .{},
    class: TurnClass = .system,
    voice: bool = false,
    carried: bool = false,
    boundary: bool = false,
    stamp_ms: ?i64 = null,
    aired_at_ms: ?i64 = null,
    duration_ms: i64 = 3000,

    pub fn visible(self: *const Turn, lead_ms: i64, now_ms: i64) bool {
        const aired = self.aired_at_ms orelse return true;
        const audible = aired +| @max(0, lead_ms);
        return audible <= now_ms or audible -| now_ms > max_hold_ms;
    }

    pub fn ticker(self: *const Turn, song_id: []const u8) bool {
        if (self.carried or self.text.len == 0) return false;
        return self.class == .voice or (self.class == .dj and
            (self.track_id.len == 0 or std.mem.eql(u8, self.track_id.slice(), song_id)));
    }
};

pub const Talking = struct { talking: bool = false, turn: ?usize = null };

pub fn talkingState(turns: []const Turn, lead_ms: i64, now_ms: i64) Talking {
    var index = turns.len;
    while (index > 0) {
        index -= 1;
        const turn = &turns[index];
        if (!turn.voice or turn.carried) continue;
        const stamp = turn.aired_at_ms orelse turn.stamp_ms orelse continue;
        const start = stamp +| @max(0, lead_ms);
        if (start > now_ms) continue;
        if (now_ms < start +| turn.duration_ms) return .{ .talking = true, .turn = index };
        break;
    }
    return .{};
}

const testing = std.testing;
const old = Track{ .title = "Old", .artist = "Artist" };
const next = Track{ .title = "Next", .artist = "Artist" };

fn heldController() Controller {
    var controller: Controller = .{};
    controller.receiveTrack(old, 22, 100_000);
    _ = controller.advance(100_000);
    controller.receiveTrack(next, 22, 105_000);
    controller.receiveCurrent(.{ .title = "Next", .artist = "Artist", .started_at_ms = 105_000 });
    return controller;
}

test "track hold releases at the listener start and cold start has no earlier track" {
    var controller = heldController();
    try testing.expect(controller.advance(105_000) == null);
    try testing.expect(controller.advance(126_999) == null);
    const publication = controller.advance(127_000).?;
    try testing.expectEqualStrings("Next", publication.track.?.title);
    try testing.expectEqual(@as(?i64, 127_000), publication.audible_at_ms);
    try testing.expect(publication.changed and !publication.first);
    try testing.expect(controller.advance(128_000) == null);
}

test "back-to-back changes replace a hold and reversion cancels it" {
    var controller = heldController();
    controller.receiveTrack(.{ .title = "Third", .artist = "Artist", .legacy_start_ms = 110_000 }, 22, 110_000);
    try testing.expect(controller.advance(127_000) == null);
    try testing.expectEqualStrings("Third", controller.advance(132_000).?.track.?.title);
    controller = heldController();
    controller.receiveTrack(old, 22, 110_000);
    try testing.expect(!controller.advance(110_000).?.changed);
    try testing.expect(controller.advance(127_000) == null);
}

test "station switch clears held data and buffer zero means no hold" {
    var controller = heldController();
    controller.reset();
    try testing.expect(controller.advance(127_000) == null);
    try testing.expectEqual(@as(i64, 0), controller.lead_ms);
    controller.receiveTrack(next, 0, 105_000);
    const publication = controller.advance(105_000).?;
    try testing.expect(publication.first);
    controller = heldController();
    controller.receiveTrack(next, 0, 106_000);
    try testing.expect(controller.advance(106_000) != null);
}

test "poll legs join in either order and failures terminate the join" {
    inline for (.{ true, false }) |np_first| {
        var controller: Controller = .{};
        controller.receiveTrack(old, 22, 100_000);
        _ = controller.advance(100_000);
        try testing.expect(controller.beginPoll());
        try testing.expect(!controller.beginPoll());
        if (np_first) controller.receiveTrack(next, 22, 105_000) else controller.receiveCurrent(.{ .title = "Next", .started_at_ms = 105_000 });
        try testing.expect(controller.advance(105_000) == null);
        if (np_first) controller.receiveCurrent(.{ .title = "Next", .started_at_ms = 105_000 }) else controller.receiveTrack(next, 22, 105_000);
        try testing.expect(controller.advance(105_000) == null);
        try testing.expect(controller.advance(127_000) != null);
        try testing.expect(controller.beginPoll());
        controller.failTrack();
        controller.receiveCurrent(null);
        try testing.expect(controller.beginPoll());
    }
}

test "repeated pending polls preserve the deadline and metadata" {
    var controller = heldController();
    try testing.expect(controller.advance(105_000) == null);
    controller.receiveTrack(.{ .title = "Next", .artist = "Artist", .album = "Updated" }, null, 110_000);
    const publication = controller.advance(127_000).?;
    try testing.expectEqualStrings("Updated", publication.track.?.album);
    try testing.expectEqual(@as(?i64, 127_000), publication.audible_at_ms);
}

test "same track converges on matching state and null clears immediately" {
    var controller: Controller = .{};
    controller.receiveTrack(old, 22, 100_000);
    try testing.expectEqual(@as(?i64, 100_000), controller.advance(100_000).?.audible_at_ms);
    controller.receiveCurrent(.{ .title = "Old", .started_at_ms = 80_000 });
    // Mobile tolerates clock drift through 2.5s.
    try testing.expectEqual(@as(?i64, 100_000), controller.advance(100_000).?.audible_at_ms);
    controller.receiveCurrent(.{ .title = "Old", .started_at_ms = 70_000 });
    try testing.expectEqual(@as(?i64, 92_000), controller.advance(100_000).?.audible_at_ms);
    controller.receiveTrack(null, null, 101_000);
    try testing.expect(controller.advance(101_000).?.track == null);
}

test "mismatched or future server stamp falls back to first seen" {
    var controller: Controller = .{};
    controller.receiveTrack(next, 22, 100_000);
    controller.receiveCurrent(.{ .title = "Other", .started_at_ms = 99_000 });
    try testing.expectEqual(@as(?i64, 100_000), controller.advance(100_000).?.audible_at_ms);
    controller.receiveCurrent(.{ .title = "Next", .started_at_ms = 200_000 });
    try testing.expectEqual(@as(?i64, 100_000), controller.advance(100_000).?.audible_at_ms);
}

test "buffer clamps finite values and preserves missing or invalid values" {
    try testing.expectEqual(@as(i64, 22_500), bufferMs(22.5, 0));
    try testing.expectEqual(@as(i64, 0), bufferMs(-1, 22_000));
    try testing.expectEqual(@as(i64, 60_000), bufferMs(1e300, 0));
    try testing.expectEqual(@as(i64, 22_000), bufferMs(null, 22_000));
    try testing.expectEqual(@as(i64, 22_000), bufferMs(std.math.nan(f64), 22_000));
    try testing.expectEqual(@as(i64, 22_000), bufferMs(std.math.inf(f64), 22_000));
}

test "elapsed clamps at both bounds with saturated timestamp arithmetic" {
    try testing.expectEqual(@as(i64, 0), elapsedMs(100_000, 122_000, 137_000));
    try testing.expectEqual(@as(i64, 79_000), elapsedMs(201_000, 122_000, 137_000));
    try testing.expectEqual(@as(i64, 137_000), elapsedMs(400_000, 122_000, 137_000));
    try testing.expectEqual(@as(i64, 0), elapsedMs(0, std.math.maxInt(i64), 0));
    try testing.expectEqual(std.math.maxInt(i64), elapsedMs(std.math.maxInt(i64), std.math.minInt(i64), 0));
}

test "ISO timestamps accept fractions offsets and leap days and reject junk" {
    try testing.expectEqual(@as(?i64, 0), isoMs("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 123), isoMs("1970-01-01T01:00:00.123+01:00"));
    try testing.expectEqual(@as(?i64, 120), isoMs("1970-01-01T00:00:00.12Z"));
    try testing.expectEqual(isoMs("2026-10-09T12:00:00Z"), isoMs("2026-10-09T07:00:00-05:00"));
    try testing.expect(isoMs("2024-02-29T12:00:00Z") != null);
    inline for (.{ "junk", "2026-02-29T12:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:00.Z" }) |bad|
        try testing.expect(isoMs(bad) == null);
}

test "booth lines release at aired plus buffer and future holds fail open" {
    const turn = Turn{ .aired_at_ms = 100_000 };
    try testing.expect(!turn.visible(22_000, 121_999));
    try testing.expect(turn.visible(22_000, 122_000));
    try testing.expect(turn.visible(0, 100_000));
    try testing.expect((Turn{}).visible(22_000, 100_000));
    try testing.expect((Turn{ .aired_at_ms = 300_000 }).visible(22_000, 100_000));
    try testing.expect(!(Turn{ .aired_at_ms = 198_000 }).visible(22_000, 100_000));
}

test "ticker skips carried and unrelated pick reasoning" {
    var turn: Turn = .{ .class = .dj };
    turn.text.set("Picked a song");
    turn.track_id.set("next");
    try testing.expect(!turn.ticker("current"));
    try testing.expect(turn.ticker("next"));
    turn.class = .voice;
    try testing.expect(turn.ticker("current"));
    turn.carried = true;
    try testing.expect(!turn.ticker("current"));
}

test "voice duration uses the measured clip or mobile word count estimate" {
    const words = "one two three four five six seven eight nine ten";
    try testing.expectEqual(@as(i64, 5046), speechMs(words));
    try testing.expectEqual(@as(i64, 3000), speechMs(""));
    try testing.expectEqual(@as(i64, 12345), lineMs(12345, words));
    inline for (.{ 0.0, -1.0, std.math.nan(f64), std.math.inf(f64), 960_000.0 }) |bad|
        try testing.expectEqual(@as(i64, 5046), lineMs(bad, words));
    try testing.expect(isVoice("event", "station-id"));
    try testing.expect(isVoice("SEGMENT", "handoff"));
    try testing.expect(!isVoice("event", "show-boundary"));
}

test "talking window follows listener time and pending speech cannot mask heard speech" {
    var turns = [_]Turn{
        .{ .voice = true, .aired_at_ms = 100_000, .duration_ms = 10_000 },
        .{ .voice = true, .stamp_ms = 125_000, .duration_ms = 5000 },
    };
    try testing.expect(!talkingState(&turns, 22_000, 121_999).talking);
    try testing.expectEqual(@as(?usize, 0), talkingState(&turns, 22_000, 122_000).turn);
    try testing.expect(talkingState(&turns, 22_000, 131_999).talking);
    try testing.expect(!talkingState(&turns, 22_000, 132_000).talking);
    try testing.expectEqual(@as(?usize, 1), talkingState(&turns, 22_000, 147_000).turn);
    turns[1].carried = true;
    try testing.expect(!talkingState(&turns, 22_000, 147_000).talking);
    turns[0].carried = true;
    try testing.expect(!talkingState(&turns, 22_000, 122_000).talking);
}

test "latest started voice decides even when an older clip would still be playing" {
    const turns = [_]Turn{
        .{ .voice = true, .aired_at_ms = 100_000, .duration_ms = 60_000 },
        .{ .voice = true, .aired_at_ms = 110_000, .duration_ms = 3000 },
    };
    try testing.expect(!talkingState(&turns, 22_000, 140_000).talking);
}

test "a first real track after an empty feed has nothing to hold" {
    var controller: Controller = .{};
    controller.receiveTrack(null, 22, 100_000);
    try testing.expect(controller.advance(100_000).?.track == null);
    controller.receiveTrack(next, null, 105_000);
    controller.receiveCurrent(.{ .title = "Next", .started_at_ms = 105_000 });
    const publication = controller.advance(105_000).?;
    try testing.expect(publication.first);
    try testing.expectEqual(@as(?i64, 127_000), publication.audible_at_ms);
}

test "owned snapshots survive copying and preserve UTF-8 truncation" {
    var original: Controller = .{};
    original.receiveTrack(.{ .title = "First", .artist = "Artist" }, 22, 100_000);
    var copy = original;
    original.receiveTrack(.{ .title = "Changed" }, 0, 100_000);
    try testing.expectEqualStrings("First", copy.advance(100_000).?.track.?.title);
    var text: Text(4) = .{};
    text.set("ABCé");
    try testing.expectEqualStrings("ABC", text.slice());
}

test "speech estimate counts Unicode whitespace and caps long scripts" {
    try testing.expectEqual(@as(i64, 5046), speechMs("one\u{a0}two\u{2009}three four five six seven eight nine ten"));
    try testing.expectEqual(@as(i64, 45000), speechMs("word " ** 500));
}

test "a failed later state poll cannot release a resolved track early" {
    var controller = heldController();
    try testing.expect(controller.advance(105_000) == null);
    try testing.expect(controller.beginPoll());
    controller.receiveTrack(next, null, 110_000);
    controller.receiveCurrent(null);
    try testing.expect(controller.advance(110_000) == null);
    try testing.expectEqualStrings("Next", controller.advance(127_000).?.track.?.title);
}

test "a resolved hold releases while the next poll is still outstanding" {
    var controller = heldController();
    try testing.expect(controller.advance(105_000) == null);
    try testing.expect(controller.beginPoll());
    controller.receiveTrack(.{ .title = "Third", .artist = "Artist", .legacy_start_ms = 125_000 }, null, 126_000);
    try testing.expectEqualStrings("Next", controller.advance(127_000).?.track.?.title);
    controller.receiveCurrent(.{ .title = "Third", .started_at_ms = 125_000 });
    try testing.expect(controller.advance(127_000) == null);
    try testing.expectEqualStrings("Third", controller.advance(147_000).?.track.?.title);
}

// Cancelled effect keys stay occupied until their terminal is delivered. A
// station generation also rejects queued replies after the key pair wraps.
pub const FetchSlots = struct {
    busy: [59]bool = [_]bool{false} ** 59,
    generation: [59]u64 = [_]u64{0} ** 59,

    pub fn start(self: *FetchSlots, key: u64, generation: u64) bool {
        if (key >= self.busy.len or self.busy[@intCast(key)]) return false;
        self.busy[@intCast(key)] = true;
        self.generation[@intCast(key)] = generation;
        return true;
    }

    pub fn finish(self: *FetchSlots, key: u64, generation: u64) bool {
        if (key >= self.busy.len) return false;
        self.busy[@intCast(key)] = false;
        return self.generation[@intCast(key)] == generation;
    }

    pub fn available(self: *const FetchSlots, key: u64) bool {
        return key < self.busy.len and !self.busy[@intCast(key)];
    }
};

test "fetch slots wait for terminals before key reuse and reject old generations" {
    var slots: FetchSlots = .{};
    try testing.expect(slots.start(51, 1));
    try testing.expect(slots.start(53, 2));
    try testing.expect(!slots.start(51, 3));
    try testing.expect(!slots.finish(51, 3));
    try testing.expect(slots.start(51, 3));
    try testing.expect(slots.finish(51, 3));
    try testing.expect(!slots.start(1000, 4));
}
