//! Typed decoders for the station's JSON payloads. Uses std.json with
//! ignore_unknown_fields so we declare only the handful of fields the player
//! needs and the rest of each large payload is skipped. Strings in the parsed
//! result are arena-owned — callers COPY what the model keeps, then deinit.

const std = @import("std");

pub const Track = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    subsonic_id: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    duration: ?f64 = null, // seconds; may be int or float in JSON
};

pub const Dj = struct {
    name: ?[]const u8 = null,
};

pub const ActiveShow = struct {
    name: ?[]const u8 = null,
};

// listeners is an object {current, peak}, not a scalar.
pub const Listeners = struct {
    current: ?i64 = null,
    peak: ?i64 = null,
};

pub const NowPlaying = struct {
    nowPlaying: ?Track = null,
    dj: ?Dj = null,
    activeShow: ?ActiveShow = null,
    listeners: ?Listeners = null,
    streamOnline: ?bool = null,
};

pub const Current = struct {
    startedAt: ?[]const u8 = null,
};

pub const Theme = struct {
    active: ?[]const u8 = null,
};

pub const StationState = struct {
    current: ?Current = null,
    theme: ?Theme = null,
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
    mode: ?[]const u8 = null,
    tokens: ?Tokens = null,
};

pub const ThemesPayload = struct {
    active: ?[]const u8 = null,
    themes: ?[]ThemeEntry = null,
};

// POST /api/request → 202 { success, requestId, status }
pub const RequestPost = struct {
    requestId: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

// GET /api/request/:id → { status, message, queuePosition, ... }
pub const RequestStatus = struct {
    status: ?[]const u8 = null,
    message: ?[]const u8 = null,
    queuePosition: ?i64 = null,
};

// GET /api/session → { messages: [{ role, kind, text }] }
pub const SessionMsg = struct {
    role: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    text: ?[]const u8 = null,
};
pub const Session = struct {
    messages: ?[]SessionMsg = null,
};

// settings.json on disk
pub const Settings = struct {
    volume: ?f32 = null,
    skin: ?[]const u8 = null,
    themeOverride: ?[]const u8 = null,
    station: ?[]const u8 = null,
};

// Parse `body` into T, tolerating unknown/extra fields. Caller owns the result
// and MUST `defer parsed.deinit()`; copy any strings before that.
pub fn parse(comptime T: type, alloc: std.mem.Allocator, body: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, body, .{ .ignore_unknown_fields = true });
}
