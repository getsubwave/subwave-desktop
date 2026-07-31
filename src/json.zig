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
    name: ?[]const u8 = null,
};

pub const ActiveShow = struct {
    name: ?[]const u8 = null,
    persona: ?Persona = null,
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
};
pub const Context = struct {
    time: ?TimeCtx = null,
    weather: ?WeatherCtx = null,
    dominantMood: ?[]const u8 = null,
};

// Optional-mount flags on /now-playing — which extra stream formats the
// station serves (MP3 is the always-on floor and carries no flag).
pub const StreamInfo = struct {
    opusEnabled: ?bool = null,
    flacEnabled: ?bool = null,
    aacEnabled: ?bool = null,
};

pub const NowPlaying = struct {
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
};

// Private-station flags riding /api/state — booleans only, never the
// password. Old stations omit the object entirely (→ both false).
pub const Privacy = struct {
    privatePlayer: ?bool = null,
    listenerAuth: ?bool = null,
};

pub const StationState = struct {
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
pub const SessionMsg = struct {
    // ISO timestamp string OR epoch number depending on station version — a
    // Value survives both (a typed ?[]const u8 would fail the whole parse on
    // a numeric t).
    t: ?std.json.Value = null,
    role: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    text: ?[]const u8 = null,
};
pub const Session = struct {
    messages: ?[]SessionMsg = null,
};

// /api/schedule (the show catalogue + personas; the 7x24 grid is ignored here)
pub const SchedPersona = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};
pub const SchedShow = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    personaId: ?[]const u8 = null,
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
pub const Settings = struct {
    volume: ?f32 = null,
    themeOverride: ?[]const u8 = null,
    streamFormat: ?[]const u8 = null,
    station: ?[]const u8 = null,
    stationName: ?[]const u8 = null,
    // Shared station password for private stations (plaintext, like the web
    // player's localStorage token); "" / absent = none stored.
    stationPassword: ?[]const u8 = null,
    recents: ?[]SettingsRecent = null,
    discordEnabled: ?bool = null,
};

// Parse `body` into T, tolerating unknown/extra fields. Caller owns the result
// and MUST `defer parsed.deinit()`; copy any strings before that.
pub fn parse(comptime T: type, alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, body, .{ .ignore_unknown_fields = true });
}
