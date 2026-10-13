//! Typed decoders for the station's JSON payloads. Uses std.json with
//! ignore_unknown_fields so we declare only the handful of fields the player
//! needs and the rest of each large payload is skipped. Strings in the parsed
//! result are arena-owned — callers COPY what the model keeps, then deinit.

const std = @import("std");

/// GitHub `releases/latest` payload — only the tag survives decoding.
pub const Release = struct {
    tag_name: ?[]const u8 = null,
};

pub const Track = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    subsonic_id: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    duration: ?f64 = null, // seconds; may be int or float in JSON
    timestamp: ?i64 = null, // unix seconds the track started airing
    year: ?i64 = null,
    bpm: ?f64 = null, // library analysis may emit fractional BPM
    musicalKey: ?[]const u8 = null,
    moods: ?[][]const u8 = null,
    energy: ?[]const u8 = null,
};

pub const Dj = struct {
    name: ?[]const u8 = null,
};

pub const Persona = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};

pub const ActiveShow = struct {
    name: ?[]const u8 = null,
    persona: ?Persona = null,
    guests: ?[]Persona = null,
};

// listeners is an object {current, peak}, not a scalar.
pub const Listeners = struct {
    current: ?i64 = null,
    peak: ?i64 = null,
};

// Context envelope on /now-playing — drives the masthead vibe line.
pub const TimeCtx = struct {
    show: ?[]const u8 = null,
    vibe: ?[]const u8 = null,
};
pub const WeatherCtx = struct {
    condition: ?[]const u8 = null,
    temp: ?f64 = null,
    location: ?[]const u8 = null,
};
pub const ClockCtx = struct { hhmm: ?[]const u8 = null };
pub const DateCtx = struct { dayOfWeek: ?i64 = null, iso: ?[]const u8 = null };
pub const FestivalCtx = struct {
    name: ?[]const u8 = null,
};
pub const Context = struct {
    time: ?TimeCtx = null,
    weather: ?WeatherCtx = null,
    dominantMood: ?[]const u8 = null,
    clock: ?ClockCtx = null,
    date: ?DateCtx = null,
    festival: ?FestivalCtx = null,
};

// The station's stream description on /now-playing: which extra mounts it
// serves (MP3 is the always-on floor and carries no flag), plus the shape of
// its PRIMARY mount. `format`/`bitrate` describe that one mount only — the one
// named in `mount` — so a listener tuned to a different format must not be
// shown this bitrate. See Model.stream_primary.
pub const StreamInfo = struct {
    bufferSeconds: ?std.json.Value = null,
    opusEnabled: ?bool = null,
    flacEnabled: ?bool = null,
    aacEnabled: ?bool = null,
    format: ?[]const u8 = null,
    bitrate: ?i64 = null,
};

pub const NowPlaying = struct {
    timezone: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    nowPlaying: ?Track = null,
    context: ?Context = null,
    dj: ?Dj = null,
    activeShow: ?ActiveShow = null,
    listeners: ?Listeners = null,
    stream: ?StreamInfo = null,
    streamOnline: ?bool = null,
    llmTokens: ?i64 = null,
};

pub const Theme = struct {
    active: ?[]const u8 = null,
};

// /api/state — theme flip signal + the queue/history ledger (Timeline panel).
pub const QueueEntry = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    requestedBy: ?[]const u8 = null,
    t: ?[]const u8 = null, // ISO timestamp on history entries
    startedAt: ?[]const u8 = null,
    queuedAt: ?[]const u8 = null,
};

// Private-station flags riding /api/state — booleans only, never the
// password. Old stations omit the object entirely (→ both false).
pub const Privacy = struct {
    privatePlayer: ?bool = null,
    listenerAuth: ?bool = null,
};

pub const CurrentTrack = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    subsonic_id: ?[]const u8 = null,
    startedAt: ?[]const u8 = null,
};

pub const StationState = struct {
    current: ?CurrentTrack = null,
    theme: ?Theme = null,
    upcoming: ?[]QueueEntry = null,
    history: ?[]QueueEntry = null,
    privacy: ?Privacy = null,
};

// /api/dj — station identity for the masthead + onboarding booth step.
pub const DjPublic = struct {
    name: ?[]const u8 = null,
    station: ?[]const u8 = null,
    location: ?[]const u8 = null,
    tagline: ?[]const u8 = null,
};

// {directory}/stations.json — curated community stations (Discover).
pub const DirectoryStation = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    location: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    featured: ?bool = null,
};

// /api/themes — the 7 CSS tokens carry "--" prefixes, so the struct fields use
// @"--…" names, which std.json matches to the JSON keys verbatim.
pub const Tokens = struct {
    @"--bg": ?[]const u8 = null,
    @"--ink": ?[]const u8 = null,
    @"--muted": ?[]const u8 = null,
    @"--accent": ?[]const u8 = null,
    @"--overlay": ?[]const u8 = null,
    @"--soft-border": ?[]const u8 = null,
    @"--field": ?[]const u8 = null,
};

pub const ThemeEntry = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    tokens: ?Tokens = null,
};

pub const ThemesPayload = struct {
    active: ?[]const u8 = null,
    themes: ?[]ThemeEntry = null,
};

// The track a resolved request points at.
pub const RequestTrack = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
};

// POST /api/request → 202 { success, requestId, ack, status, ... }
pub const RequestPost = struct {
    requestId: ?[]const u8 = null,
    status: ?[]const u8 = null,
    ack: ?[]const u8 = null,
};

// GET /api/request/:id → { status, message, ack, track, queuePosition, ... }
pub const RequestStatus = struct {
    status: ?[]const u8 = null,
    message: ?[]const u8 = null,
    ack: ?[]const u8 = null,
    track: ?RequestTrack = null,
    queuePosition: ?i64 = null,
};

// GET /api/session → { messages: [{ t, role, kind, text }] }
pub const ShowBoundary = struct {
    at: ?[]const u8 = null,
    show: ?[]const u8 = null,
    persona: ?[]const u8 = null,
};

pub const SessionMeta = struct {
    airedAt: ?std.json.Value = null,
    durationMs: ?std.json.Value = null,
    carried: ?std.json.Value = null,
    personaName: ?[]const u8 = null,
    trackId: ?[]const u8 = null,
    boundary: ?ShowBoundary = null,
};

pub const SessionMsg = struct {
    // ISO timestamp string OR epoch number depending on station version — a
    // Value survives both (a typed ?[]const u8 would fail the whole parse on
    // a numeric t).
    t: ?std.json.Value = null,
    role: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    text: ?[]const u8 = null,
    meta: ?SessionMeta = null,
};
pub const Session = struct {
    messages: ?[]SessionMsg = null,
};

// /api/schedule (the weekly grid, shows and public persona roster)
pub const SchedPersona = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tagline: ?[]const u8 = null,
    soul: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
};
pub const SchedShow = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    personaId: ?[]const u8 = null,
    guestPersonaIds: ?[][]const u8 = null,
};
// The 7x24 grid: JSON object keyed "0".."6" (Sun..Sat), each a 24-slot array
// of showId|null. @"N" field names match the numeric-string keys verbatim.
pub const SchedGrid = struct {
    @"0": ?[]?[]const u8 = null,
    @"1": ?[]?[]const u8 = null,
    @"2": ?[]?[]const u8 = null,
    @"3": ?[]?[]const u8 = null,
    @"4": ?[]?[]const u8 = null,
    @"5": ?[]?[]const u8 = null,
    @"6": ?[]?[]const u8 = null,

    pub fn day(self: *const SchedGrid, index: usize) ?[]?[]const u8 {
        return switch (index) {
            0 => self.@"0",
            1 => self.@"1",
            2 => self.@"2",
            3 => self.@"3",
            4 => self.@"4",
            5 => self.@"5",
            6 => self.@"6",
            else => null,
        };
    }
};

pub const SchedulePayload = struct {
    timezone: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    soulsPublished: ?bool = null,
    personas: ?[]SchedPersona = null,
    shows: ?[]SchedShow = null,
    schedule: ?SchedGrid = null,
};

// /api/like — GET returns liked-state + count for the current airing; the
// POST response carries the same fields plus ok/alreadyLiked. One struct
// covers both (unknown fields are ignored by parse()).
pub const LikeStatus = struct {
    enabled: ?bool = null,
    ok: ?bool = null,
    songId: ?[]const u8 = null,
    liked: ?bool = null,
    alreadyLiked: ?bool = null,
    count: ?i64 = null,
};

// settings.json on disk (v2: recents ride along; the legacy "skin" key is
// simply ignored on load — old files still parse).
pub const SettingsRecent = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
};
pub const SettingsStation = struct {
    streamFormat: ?[]const u8 = null,
    stationPassword: ?[]const u8 = null, // Linux fallback; other hosts import into the vault
};
pub const Health = struct {
    status: ?[]const u8 = null,
};
pub const Settings = struct {
    volume: ?f32 = null,
    themeOverride: ?[]const u8 = null,
    streamFormat: ?[]const u8 = null,
    station: ?[]const u8 = null,
    stationName: ?[]const u8 = null,
    // Legacy single-station password, imported on load and never written.
    stationPassword: ?[]const u8 = null,
    stationSettings: ?std.json.ArrayHashMap(SettingsStation) = null,
    recents: ?[]SettingsRecent = null,
    discordEnabled: ?bool = null,
    // Listener-entered Discord application ID (public identifier, not a
    // secret); ""/absent = use the build-time discord.zon default, if any.
    discordClientId: ?[]const u8 = null,
    // Desktop track-change notifications; absent = off (opt-in).
    notifyTrack: ?bool = null,
};

// Parse `body` into T, tolerating unknown/extra fields. Caller owns the result
// and MUST `defer parsed.deinit()`; copy any strings before that.
pub fn parse(comptime T: type, alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, body, .{ .ignore_unknown_fields = true });
}

test "listener timing fields decode alongside unknown public payload fields" {
    const parsed = try parse(NowPlaying, std.testing.allocator,
        \\{"nowPlaying":{"title":"Song","subsonic_id":"song","unused":true},"stream":{"bufferSeconds":22.5,"mount":"/stream.mp3"},"future":{}}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 22.5), parsed.value.stream.?.bufferSeconds.?.float);
    const state = try parse(StationState, std.testing.allocator,
        \\{"current":{"title":"Song","artist":"Artist","subsonic_id":"song","startedAt":"2026-10-09T12:00:00Z","source":"auto"},"future":true}
    );
    defer state.deinit();
    try std.testing.expectEqualStrings("2026-10-09T12:00:00Z", state.value.current.?.startedAt.?);
    const session = try parse(Session, std.testing.allocator,
        \\{"messages":[{"t":123,"role":"segment","kind":"link","text":"Goodnight","meta":{"airedAt":"2026-10-09T12:00:00Z","durationMs":12000,"carried":true,"personaName":"Bob","trackId":"song","internal":{}}},{"role":"event","kind":"show-boundary","meta":{"boundary":{"at":"2026-10-09T12:00:00Z","show":"Blue Hour","persona":"Heer","fromSessionId":"prev"}}}]}
    );
    defer session.deinit();
    const turns = session.value.messages.?;
    try std.testing.expectEqual(@as(i64, 123), turns[0].t.?.integer);
    try std.testing.expectEqual(@as(i64, 12000), turns[0].meta.?.durationMs.?.integer);
    try std.testing.expect(turns[0].meta.?.carried.?.bool);
    try std.testing.expectEqualStrings("Bob", turns[0].meta.?.personaName.?);
    try std.testing.expectEqualStrings("song", turns[0].meta.?.trackId.?);
    try std.testing.expectEqualStrings("Blue Hour", turns[1].meta.?.boundary.?.show.?);
}

test "invalid optional timing types do not discard an otherwise valid feed" {
    const np = try parse(NowPlaying, std.testing.allocator,
        \\{"nowPlaying":{"title":"Still playing"},"stream":{"bufferSeconds":"unknown"}}
    );
    defer np.deinit();
    try std.testing.expectEqualStrings("Still playing", np.value.nowPlaying.?.title.?);
    const session = try parse(Session, std.testing.allocator,
        \\{"messages":[{"role":"segment","text":"Hello","meta":{"airedAt":123,"durationMs":"unknown","carried":"yes"}}]}
    );
    defer session.deinit();
    try std.testing.expectEqualStrings("Hello", session.value.messages.?[0].text.?);
}
