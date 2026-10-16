//! Bounded, owned projections of the station's closed HTTP API.
const std = @import("std");

pub const max_body_bytes: usize = 256 * 1024;
pub const max_text_bytes: usize = 512;
pub const max_themes: usize = 32;
pub const max_schedule_entries: usize = 64;
pub const max_session_messages: usize = 120;
pub const max_timeline_entries: usize = 64;
pub const max_track_moods: usize = 32;
pub const schedule_hours: usize = 24;

pub const Endpoint = enum { health, now_playing, state, themes, session, schedule, station_auth };

pub const HealthStatus = enum { @"on-air" };
pub const Health = struct {
    status: HealthStatus,

    pub fn isHealthy(self: Health) bool {
        return self.status == .@"on-air";
    }
};
pub const StationAuth = struct { ok: ?bool = null };
pub const Track = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    duration_seconds: ?f64 = null,
    started_at_seconds: ?i64 = null,
    source_id: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    year: ?i64 = null,
    bpm: ?f64 = null,
    musical_key: ?[]const u8 = null,
    moods: []const []const u8 = &.{},
    energy: ?[]const u8 = null,
};
pub const TimeContext = struct { show: ?[]const u8 = null, vibe: ?[]const u8 = null };
pub const WeatherContext = struct { condition: ?[]const u8 = null, temperature: ?f64 = null };
pub const NowPlayingContext = struct { time: ?TimeContext = null, weather: ?WeatherContext = null, dominant_mood: ?[]const u8 = null };
pub const Dj = struct { name: ?[]const u8 = null };
pub const ShowIdentity = struct { name: ?[]const u8 = null, persona_name: ?[]const u8 = null };
pub const Listeners = struct { current: ?i64 = null, peak: ?i64 = null };
pub const StreamFlags = struct {
    opus: bool = false,
    flac: bool = false,
    aac: bool = false,
    format: ?[]const u8 = null,
    bitrate_kbps: ?i64 = null,
};
pub const NowPlaying = struct {
    track: ?Track = null,
    listeners: ?Listeners = null,
    stream: ?StreamFlags = null,
    stream_online: ?bool = null,
    context: ?NowPlayingContext = null,
    dj: ?Dj = null,
    active_show: ?ShowIdentity = null,
};
pub const Privacy = struct { private_player: bool = false, listener_auth: bool = false };
pub const QueueEntry = struct {
    source_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    requested_by: ?[]const u8 = null,
    source: ?[]const u8 = null,
    started_at: ?[]const u8 = null,
    ended_at: ?[]const u8 = null,
    queued_at: ?[]const u8 = null,
    legacy_t: ?[]const u8 = null,
    sent: ?bool = null,
};
pub const State = struct { active_theme: ?[]const u8 = null, privacy: Privacy = .{}, upcoming: []const QueueEntry = &.{}, history: []const QueueEntry = &.{} };
pub const Tokens = struct {
    bg: ?[]const u8 = null,
    ink: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    overlay: ?[]const u8 = null,
    soft_border: ?[]const u8 = null,
    field: ?[]const u8 = null,
};
pub const Theme = struct { id: ?[]const u8 = null, name: ?[]const u8 = null, tokens: ?Tokens = null };
pub const Themes = struct { active: ?[]const u8 = null, items: []const Theme = &.{} };
pub const SessionTime = union(enum) { text: []const u8, epoch: i64 };
pub const SessionMessage = struct { t: ?SessionTime = null, role: ?[]const u8 = null, kind: ?[]const u8 = null, text: ?[]const u8 = null };
pub const Session = struct { messages: []const SessionMessage = &.{} };
pub const Persona = struct { id: ?[]const u8 = null, name: ?[]const u8 = null };
pub const Show = struct { id: ?[]const u8 = null, name: ?[]const u8 = null, topic: ?[]const u8 = null, persona_id: ?[]const u8 = null };
pub const ScheduleGrid = struct {
    days: [7][]const ?[]const u8 = @splat(&.{}),

    pub fn day(self: *const ScheduleGrid, index: usize) ?[]const ?[]const u8 {
        if (index >= self.days.len) return null;
        return self.days[index];
    }
};
pub const Schedule = struct { personas: []const Persona = &.{}, shows: []const Show = &.{}, grid: ?ScheduleGrid = null };

pub const Payload = union(Endpoint) {
    health: Health,
    now_playing: NowPlaying,
    state: State,
    themes: Themes,
    session: Session,
    schedule: Schedule,
    station_auth: StationAuth,
};

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    payload: Payload,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const RawTrack = struct { title: ?[]const u8 = null, artist: ?[]const u8 = null, album: ?[]const u8 = null, subsonic_id: ?[]const u8 = null, genre: ?[]const u8 = null, duration: ?f64 = null, timestamp: ?i64 = null, year: ?i64 = null, bpm: ?f64 = null, musicalKey: ?[]const u8 = null, moods: ?[][]const u8 = null, energy: ?[]const u8 = null };
const RawTimeContext = struct { show: ?[]const u8 = null, vibe: ?[]const u8 = null };
const RawWeatherContext = struct { condition: ?[]const u8 = null, temp: ?f64 = null };
const RawContext = struct { time: ?RawTimeContext = null, weather: ?RawWeatherContext = null, dominantMood: ?[]const u8 = null };
const RawDj = struct { name: ?[]const u8 = null };
const RawPersonaName = struct { name: ?[]const u8 = null };
const RawActiveShow = struct { name: ?[]const u8 = null, persona: ?RawPersonaName = null };
const RawListeners = struct { current: ?i64 = null, peak: ?i64 = null };
const RawStream = struct { opusEnabled: ?bool = null, flacEnabled: ?bool = null, aacEnabled: ?bool = null, format: ?[]const u8 = null, bitrate: ?i64 = null };
const RawNowPlaying = struct { nowPlaying: ?RawTrack = null, context: ?RawContext = null, dj: ?RawDj = null, activeShow: ?RawActiveShow = null, listeners: ?RawListeners = null, stream: ?RawStream = null, streamOnline: ?bool = null };
const RawThemeSignal = struct { active: ?[]const u8 = null };
const RawPrivacy = struct { privatePlayer: ?bool = null, listenerAuth: ?bool = null };
const RawQueueEntry = struct {
    subsonic_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    requestedBy: ?[]const u8 = null,
    source: ?[]const u8 = null,
    startedAt: ?[]const u8 = null,
    endedAt: ?[]const u8 = null,
    queuedAt: ?[]const u8 = null,
    t: ?[]const u8 = null,
    sent: ?bool = null,
};
const RawState = struct { theme: ?RawThemeSignal = null, privacy: ?RawPrivacy = null, upcoming: ?[]RawQueueEntry = null, history: ?[]RawQueueEntry = null };
const RawTokens = struct { @"--bg": ?[]const u8 = null, @"--ink": ?[]const u8 = null, @"--muted": ?[]const u8 = null, @"--accent": ?[]const u8 = null, @"--overlay": ?[]const u8 = null, @"--soft-border": ?[]const u8 = null, @"--field": ?[]const u8 = null };
const RawTheme = struct { id: ?[]const u8 = null, name: ?[]const u8 = null, tokens: ?RawTokens = null };
const RawThemes = struct { active: ?[]const u8 = null, themes: ?[]RawTheme = null };
const RawSessionMessage = struct { t: ?std.json.Value = null, role: ?[]const u8 = null, kind: ?[]const u8 = null, text: ?[]const u8 = null };
const RawSession = struct { messages: ?[]RawSessionMessage = null };
const RawPersona = struct { id: ?[]const u8 = null, name: ?[]const u8 = null };
const RawShow = struct { id: ?[]const u8 = null, name: ?[]const u8 = null, topic: ?[]const u8 = null, personaId: ?[]const u8 = null };
const RawScheduleGrid = struct { @"0": ?[]?[]const u8 = null, @"1": ?[]?[]const u8 = null, @"2": ?[]?[]const u8 = null, @"3": ?[]?[]const u8 = null, @"4": ?[]?[]const u8 = null, @"5": ?[]?[]const u8 = null, @"6": ?[]?[]const u8 = null };
const RawSchedule = struct { personas: ?[]RawPersona = null, shows: ?[]RawShow = null, schedule: ?RawScheduleGrid = null };

fn parse(comptime T: type, allocator: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn text(value: ?[]const u8) !?[]const u8 {
    const bytes = value orelse return null;
    if (bytes.len > max_text_bytes) return error.TextTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn queueEntries(a: std.mem.Allocator, source: []const RawQueueEntry) ![]const QueueEntry {
    if (source.len > max_timeline_entries) return error.TooManyTimelineEntries;
    const items = try a.alloc(QueueEntry, source.len);
    for (source, items) |v, *out| out.* = .{ .source_id = try text(v.subsonic_id), .title = try text(v.title), .artist = try text(v.artist), .album = try text(v.album), .requested_by = try text(v.requestedBy), .source = try text(v.source), .started_at = try text(v.startedAt), .ended_at = try text(v.endedAt), .queued_at = try text(v.queuedAt), .legacy_t = try text(v.t), .sent = v.sent };
    return items;
}

fn sessionTime(value: ?std.json.Value) !?SessionTime {
    const v = value orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| .{ .text = (try text(s)).? },
        .integer => |n| .{ .epoch = n },
        else => error.InvalidSessionTime,
    };
}

fn scheduleDay(source: ?[]?[]const u8) ![]const ?[]const u8 {
    const slots = source orelse return &.{};
    if (slots.len != schedule_hours) return error.InvalidScheduleHours;
    for (slots) |slot| _ = try text(slot);
    return slots;
}

pub fn decode(allocator: std.mem.Allocator, endpoint: Endpoint, body: []const u8) !Decoded {
    if (body.len > max_body_bytes) return error.BodyTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const payload: Payload = switch (endpoint) {
        .health => .{ .health = try parse(Health, a, body) },
        .station_auth => .{ .station_auth = try parse(StationAuth, a, body) },
        .now_playing => blk: {
            const raw = try parse(RawNowPlaying, a, body);
            const track: ?Track = if (raw.nowPlaying) |v| track_blk: {
                const raw_moods = v.moods orelse &.{};
                if (raw_moods.len > max_track_moods) return error.TooManyTrackMoods;
                const moods = try a.alloc([]const u8, raw_moods.len);
                for (raw_moods, moods) |mood, *out| out.* = (try text(mood)).?;
                break :track_blk .{ .title = try text(v.title), .artist = try text(v.artist), .album = try text(v.album), .duration_seconds = v.duration, .started_at_seconds = v.timestamp, .source_id = try text(v.subsonic_id), .genre = try text(v.genre), .year = v.year, .bpm = v.bpm, .musical_key = try text(v.musicalKey), .moods = moods, .energy = try text(v.energy) };
            } else null;
            const stream: ?StreamFlags = if (raw.stream) |v| .{ .opus = v.opusEnabled orelse false, .flac = v.flacEnabled orelse false, .aac = v.aacEnabled orelse false, .format = try text(v.format), .bitrate_kbps = v.bitrate } else null;
            const context: ?NowPlayingContext = if (raw.context) |v| .{ .time = if (v.time) |t| .{ .show = try text(t.show), .vibe = try text(t.vibe) } else null, .weather = if (v.weather) |w| .{ .condition = try text(w.condition), .temperature = w.temp } else null, .dominant_mood = try text(v.dominantMood) } else null;
            break :blk .{ .now_playing = .{ .track = track, .listeners = if (raw.listeners) |v| .{ .current = v.current, .peak = v.peak } else null, .stream = stream, .stream_online = raw.streamOnline, .context = context, .dj = if (raw.dj) |v| .{ .name = try text(v.name) } else null, .active_show = if (raw.activeShow) |v| .{ .name = try text(v.name), .persona_name = if (v.persona) |p| try text(p.name) else null } else null } };
        },
        .state => blk: {
            const raw = try parse(RawState, a, body);
            break :blk .{ .state = .{ .active_theme = if (raw.theme) |v| try text(v.active) else null, .privacy = if (raw.privacy) |v| .{ .private_player = v.privatePlayer orelse false, .listener_auth = v.listenerAuth orelse false } else .{}, .upcoming = try queueEntries(a, raw.upcoming orelse &.{}), .history = try queueEntries(a, raw.history orelse &.{}) } };
        },
        .themes => blk: {
            const raw = try parse(RawThemes, a, body);
            const source = raw.themes orelse &.{};
            if (source.len > max_themes) return error.TooManyThemes;
            const items = try a.alloc(Theme, source.len);
            for (source, items) |v, *out| out.* = .{ .id = try text(v.id), .name = try text(v.name), .tokens = if (v.tokens) |t| .{ .bg = try text(t.@"--bg"), .ink = try text(t.@"--ink"), .muted = try text(t.@"--muted"), .accent = try text(t.@"--accent"), .overlay = try text(t.@"--overlay"), .soft_border = try text(t.@"--soft-border"), .field = try text(t.@"--field") } else null };
            break :blk .{ .themes = .{ .active = try text(raw.active), .items = items } };
        },
        .session => blk: {
            const raw = try parse(RawSession, a, body);
            const source = raw.messages orelse &.{};
            if (source.len > max_session_messages) return error.TooManySessionMessages;
            const messages = try a.alloc(SessionMessage, source.len);
            for (source, messages) |v, *out| out.* = .{ .t = try sessionTime(v.t), .role = try text(v.role), .kind = try text(v.kind), .text = try text(v.text) };
            break :blk .{ .session = .{ .messages = messages } };
        },
        .schedule => blk: {
            const raw = try parse(RawSchedule, a, body);
            const raw_personas = raw.personas orelse &.{};
            const raw_shows = raw.shows orelse &.{};
            if (raw_personas.len > max_schedule_entries or raw_shows.len > max_schedule_entries) return error.TooManyScheduleEntries;
            const personas = try a.alloc(Persona, raw_personas.len);
            for (raw_personas, personas) |v, *out| out.* = .{ .id = try text(v.id), .name = try text(v.name) };
            const shows = try a.alloc(Show, raw_shows.len);
            for (raw_shows, shows) |v, *out| out.* = .{ .id = try text(v.id), .name = try text(v.name), .topic = try text(v.topic), .persona_id = try text(v.personaId) };
            const grid: ?ScheduleGrid = if (raw.schedule) |g| .{ .days = .{ try scheduleDay(g.@"0"), try scheduleDay(g.@"1"), try scheduleDay(g.@"2"), try scheduleDay(g.@"3"), try scheduleDay(g.@"4"), try scheduleDay(g.@"5"), try scheduleDay(g.@"6") } } else null;
            break :blk .{ .schedule = .{ .personas = personas, .shows = shows, .grid = grid } };
        },
    };
    return .{ .arena = arena, .payload = payload };
}

test "fixture projections are owned, bounded, and ignore unknown fields" {
    var decoded = try decode(std.testing.allocator, .now_playing, "{\"nowPlaying\":{\"title\":\"Fixture Track\",\"artist\":null,\"album\":\"Album\",\"duration\":180,\"timestamp\":1893499200,\"secret\":\"ignored\"},\"listeners\":{\"current\":7,\"peak\":11},\"stream\":{\"opusEnabled\":true,\"format\":\"mp3\",\"bitrate\":128},\"streamOnline\":true,\"Authorization\":\"ignored\"}");
    defer decoded.deinit();
    const value = decoded.payload.now_playing;
    try std.testing.expectEqualStrings("Fixture Track", value.track.?.title.?);
    try std.testing.expect(value.track.?.artist == null);
    try std.testing.expectEqual(@as(?i64, 7), value.listeners.?.current);
    try std.testing.expect(value.stream.?.opus);
    try std.testing.expectEqual(true, value.stream_online.?);
}

test "decoded text never borrows the response buffer" {
    var body = [_]u8{ '{', '"', 'n', 'o', 'w', 'P', 'l', 'a', 'y', 'i', 'n', 'g', '"', ':', '{', '"', 't', 'i', 't', 'l', 'e', '"', ':', '"', 'O', 'w', 'n', 'e', 'd', '"', '}', '}' };
    var decoded = try decode(std.testing.allocator, .now_playing, &body);
    defer decoded.deinit();
    @memset(&body, 'x');
    try std.testing.expectEqualStrings("Owned", decoded.payload.now_playing.track.?.title.?);
}

test "missing and null optional fields preserve defaults" {
    var missing = try decode(std.testing.allocator, .state, "{}");
    defer missing.deinit();
    try std.testing.expect(missing.payload.state.active_theme == null);
    try std.testing.expect(!missing.payload.state.privacy.private_player);
    var explicit_null = try decode(std.testing.allocator, .state, "{\"theme\":null,\"privacy\":null}");
    defer explicit_null.deinit();
    try std.testing.expect(explicit_null.payload.state.active_theme == null);
}

test "malformed and wrong typed JSON fail" {
    try std.testing.expectError(error.UnexpectedEndOfInput, decode(std.testing.allocator, .health, "{"));
    try std.testing.expectError(error.MissingField, decode(std.testing.allocator, .health, "{\"ok\":true}"));
    try std.testing.expectError(error.InvalidEnumTag, decode(std.testing.allocator, .health, "{\"status\":\"starting\"}"));
    try std.testing.expectError(error.UnexpectedToken, decode(std.testing.allocator, .state, "{\"upcoming\":[{\"queuedAt\":123}]}"));
    try std.testing.expectError(error.UnexpectedToken, decode(std.testing.allocator, .state, "{\"history\":[{\"sent\":\"yes\"}]}"));
}

test "body, text, theme, session, and schedule bounds reject instead of truncate" {
    const large = try std.testing.allocator.alloc(u8, max_body_bytes + 1);
    defer std.testing.allocator.free(large);
    @memset(large, ' ');
    try std.testing.expectError(error.BodyTooLarge, decode(std.testing.allocator, .health, large));

    const long_text = "x" ** (max_text_bytes + 1);
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"nowPlaying\":{{\"title\":\"{s}\"}}}}", .{long_text});
    defer std.testing.allocator.free(body);
    try std.testing.expectError(error.TextTooLarge, decode(std.testing.allocator, .now_playing, body));

    const theme_item = "{\"id\":\"x\"}";
    var theme_body = std.ArrayList(u8).empty;
    defer theme_body.deinit(std.testing.allocator);
    try theme_body.appendSlice(std.testing.allocator, "{\"themes\":[");
    for (0..max_themes + 1) |i| {
        if (i > 0) try theme_body.append(std.testing.allocator, ',');
        try theme_body.appendSlice(std.testing.allocator, theme_item);
    }
    try theme_body.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.TooManyThemes, decode(std.testing.allocator, .themes, theme_body.items));

    var schedule_body = std.ArrayList(u8).empty;
    defer schedule_body.deinit(std.testing.allocator);
    try schedule_body.appendSlice(std.testing.allocator, "{\"shows\":[");
    for (0..max_schedule_entries + 1) |i| {
        if (i > 0) try schedule_body.append(std.testing.allocator, ',');
        try schedule_body.appendSlice(std.testing.allocator, "{}");
    }
    try schedule_body.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.TooManyScheduleEntries, decode(std.testing.allocator, .schedule, schedule_body.items));

    var session_body = std.ArrayList(u8).empty;
    defer session_body.deinit(std.testing.allocator);
    try session_body.appendSlice(std.testing.allocator, "{\"messages\":[");
    for (0..max_session_messages + 1) |i| {
        if (i != 0) try session_body.append(std.testing.allocator, ',');
        try session_body.appendSlice(std.testing.allocator, "{}");
    }
    try session_body.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.TooManySessionMessages, decode(std.testing.allocator, .session, session_body.items));

    var persona_body = std.ArrayList(u8).empty;
    defer persona_body.deinit(std.testing.allocator);
    try persona_body.appendSlice(std.testing.allocator, "{\"personas\":[");
    for (0..max_schedule_entries + 1) |i| {
        if (i != 0) try persona_body.append(std.testing.allocator, ',');
        try persona_body.appendSlice(std.testing.allocator, "{}");
    }
    try persona_body.appendSlice(std.testing.allocator, "]}");
    try std.testing.expectError(error.TooManyScheduleEntries, decode(std.testing.allocator, .schedule, persona_body.items));

    for ([_]usize{ schedule_hours - 1, schedule_hours + 1 }) |hour_count| {
        var hours_body = std.ArrayList(u8).empty;
        defer hours_body.deinit(std.testing.allocator);
        try hours_body.appendSlice(std.testing.allocator, "{\"schedule\":{\"0\":[");
        for (0..hour_count) |i| {
            if (i != 0) try hours_body.append(std.testing.allocator, ',');
            try hours_body.appendSlice(std.testing.allocator, "null");
        }
        try hours_body.appendSlice(std.testing.allocator, "]}}");
        try std.testing.expectError(error.InvalidScheduleHours, decode(std.testing.allocator, .schedule, hours_body.items));
    }
}

test "health auth themes session and schedule fixture shapes decode" {
    var health = try decode(std.testing.allocator, .health, "{\"status\":\"on-air\"}");
    defer health.deinit();
    try std.testing.expect(health.payload.health.isHealthy());
    var auth = try decode(std.testing.allocator, .station_auth, "{\"ok\":false}");
    defer auth.deinit();
    try std.testing.expect(!auth.payload.station_auth.ok.?);
    var themes = try decode(std.testing.allocator, .themes, "{\"active\":\"dark\",\"themes\":[{\"id\":\"dark\",\"name\":\"Dark\",\"tokens\":{\"--accent\":\"#f36\"}}]}");
    defer themes.deinit();
    try std.testing.expectEqualStrings("#f36", themes.payload.themes.items[0].tokens.?.accent.?);
    var session = try decode(std.testing.allocator, .session, "{\"messages\":[{\"t\":123,\"role\":\"assistant\",\"kind\":\"speech\",\"text\":\"hello\"}]}");
    defer session.deinit();
    try std.testing.expectEqualStrings("hello", session.payload.session.messages[0].text.?);
    try std.testing.expectEqual(@as(i64, 123), session.payload.session.messages[0].t.?.epoch);
    var schedule = try decode(std.testing.allocator, .schedule, "{\"personas\":[{\"id\":\"dj\",\"name\":\"DJ\"}],\"shows\":[{\"id\":\"show\",\"name\":\"Show\",\"personaId\":\"dj\"}]}");
    defer schedule.deinit();
    try std.testing.expectEqualStrings("dj", schedule.payload.schedule.shows[0].persona_id.?);
}

test "live session cap accepts 120 messages in source order" {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "{\"messages\":[");
    for (0..max_session_messages) |i| {
        if (i != 0) try body.append(std.testing.allocator, ',');
        try body.print(std.testing.allocator, "{{\"t\":{d},\"text\":\"m{d}\"}}", .{ i, i });
    }
    try body.appendSlice(std.testing.allocator, "]}");
    var decoded = try decode(std.testing.allocator, .session, body.items);
    defer decoded.deinit();
    const messages = decoded.payload.session.messages;
    try std.testing.expectEqual(max_session_messages, messages.len);
    try std.testing.expectEqualStrings("m0", messages[0].text.?);
    try std.testing.expectEqualStrings("m119", messages[119].text.?);
}

test "schedule retains a full seven day grid and bounds collections independently" {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    try body.appendSlice(std.testing.allocator, "{\"personas\":[");
    for (0..32) |i| {
        if (i != 0) try body.append(std.testing.allocator, ',');
        try body.print(std.testing.allocator, "{{\"id\":\"p{d}\"}}", .{i});
    }
    try body.appendSlice(std.testing.allocator, "],\"shows\":[");
    for (0..40) |i| {
        if (i != 0) try body.append(std.testing.allocator, ',');
        try body.print(std.testing.allocator, "{{\"id\":\"s{d}\"}}", .{i});
    }
    try body.appendSlice(std.testing.allocator, "],\"schedule\":{");
    for (0..7) |day| {
        if (day != 0) try body.append(std.testing.allocator, ',');
        try body.print(std.testing.allocator, "\"{d}\":[", .{day});
        for (0..schedule_hours) |hour| {
            if (hour != 0) try body.append(std.testing.allocator, ',');
            if (hour == day) try body.print(std.testing.allocator, "\"s{d}\"", .{day}) else try body.appendSlice(std.testing.allocator, "null");
        }
        try body.append(std.testing.allocator, ']');
    }
    try body.appendSlice(std.testing.allocator, "}}");
    var decoded = try decode(std.testing.allocator, .schedule, body.items);
    defer decoded.deinit();
    const schedule = decoded.payload.schedule;
    try std.testing.expectEqual(@as(usize, 32), schedule.personas.len);
    try std.testing.expectEqual(@as(usize, 40), schedule.shows.len);
    for (0..7) |day| {
        const slots = schedule.grid.?.day(day).?;
        try std.testing.expectEqual(schedule_hours, slots.len);
        var expected_buf: [8]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "s{d}", .{day});
        try std.testing.expectEqualStrings(expected, slots[day].?);
    }
}

test "typed nulls unknown fields and expanded native projections are preserved safely" {
    const body = "{\"nowPlaying\":{\"title\":\"Track\",\"subsonic_id\":\"source-1\",\"genre\":\"Jazz\",\"moods\":[\"warm\",\"late\"]},\"context\":{\"time\":{\"show\":\"Night\",\"vibe\":null},\"weather\":{\"condition\":\"Rain\",\"temp\":11.5},\"dominantMood\":\"warm\"},\"dj\":{\"name\":\"Ada\"},\"activeShow\":{\"name\":\"After Dark\",\"persona\":{\"name\":\"Night DJ\"}},\"futureField\":{\"secret\":true}}";
    var now = try decode(std.testing.allocator, .now_playing, body);
    defer now.deinit();
    try std.testing.expectEqualStrings("source-1", now.payload.now_playing.track.?.source_id.?);
    try std.testing.expectEqualStrings("late", now.payload.now_playing.track.?.moods[1]);
    try std.testing.expect(now.payload.now_playing.context.?.time.?.vibe == null);
    try std.testing.expectEqualStrings("Night DJ", now.payload.now_playing.active_show.?.persona_name.?);

    var state = try decode(std.testing.allocator, .state, "{\"upcoming\":[{\"subsonic_id\":\"next-id\",\"title\":\"Next\",\"requestedBy\":null,\"source\":\"request\",\"queuedAt\":\"2026-09-07T01:01:00Z\",\"sent\":false}],\"history\":[{\"title\":\"Previous\",\"startedAt\":\"2026-09-07T01:00:00Z\",\"endedAt\":\"2026-09-07T01:03:00Z\",\"queuedAt\":\"2026-09-07T00:59:00Z\",\"t\":\"legacy-time\"}],\"unknown\":1}");
    defer state.deinit();
    try std.testing.expectEqualStrings("Next", state.payload.state.upcoming[0].title.?);
    try std.testing.expect(state.payload.state.upcoming[0].requested_by == null);
    try std.testing.expectEqualStrings("next-id", state.payload.state.upcoming[0].source_id.?);
    try std.testing.expectEqualStrings("2026-09-07T01:01:00Z", state.payload.state.upcoming[0].queued_at.?);
    try std.testing.expectEqualStrings("2026-09-07T01:00:00Z", state.payload.state.history[0].started_at.?);
    try std.testing.expectEqualStrings("2026-09-07T01:03:00Z", state.payload.state.history[0].ended_at.?);
    try std.testing.expectEqualStrings("legacy-time", state.payload.state.history[0].legacy_t.?);
}
