//! The player's heart: Model state, the Msg union, boot (init_fx), and the
//! update reducer that wires every effect. Kept free of view code — main.zig
//! does the App wiring, app.native is the view.

const std = @import("std");
const native_sdk = @import("native_sdk");
const api = @import("api.zig");
const json = @import("json.zig");
const color = @import("color.zig");
const spectrum = @import("spectrum.zig");

const base = api.default_base;

// Muted during the autonomous build so verification runs don't play through
// the speakers. Flip to 0.8 for real listening (decode/position/spectrum all
// report regardless of output volume).
pub const boot_volume: f32 = 0.0;

// ---------------------------------------------------------------- effect keys
pub const keys = struct {
    pub const audio: u64 = 10;
    pub const feed_timer: u64 = 1;
    pub const theme_timer: u64 = 2;
    pub const reconnect: u64 = 3;
    pub const fetch_np: u64 = 20;
    pub const fetch_state: u64 = 21;
    pub const fetch_themes: u64 = 22;
};

pub const Transport = enum { stopped, playing, paused };

// ------------------------------------------------------------------ model
pub const Model = struct {
    // now playing (slices point into the *_buf fixed buffers)
    title_buf: [512]u8 = undefined,
    artist_buf: [256]u8 = undefined,
    album_buf: [256]u8 = undefined,
    genre_buf: [64]u8 = undefined,
    dj_buf: [128]u8 = undefined,
    title: []const u8 = "Tuning in…",
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    dj: []const u8 = "",
    listeners: i64 = 0,
    stream_online: bool = true,

    // transport / audio
    transport: Transport = .playing,
    volume: f32 = boot_volume,
    buffering: bool = false,
    stream_failed: bool = false,
    audio_state: []const u8 = "idle",
    elapsed_ms: i64 = 0,
    spectrum_events: i64 = 0,
    retry: u6 = 0,

    // spectrum visualiser: displayed band levels (0..1) + a slice view the
    // chart series binds; refreshed by syncDisplay each update.
    band_levels: [spectrum.band_count]f32 = [_]f32{0} ** spectrum.band_count,
    bands: []const f32 = &[_]f32{},

    // feed bookkeeping
    feed_count: i64 = 0,
    offline_streak: u8 = 0,

    // theme (read live by theme.tokensFn)
    station_colors: color.StationColors = color.defaults(.light),
    theme_scheme: color.Scheme = .light,
    theme_id_buf: [64]u8 = undefined,
    theme_id: []const u8 = "classic-light",

    // derived display fields, recomputed by syncDisplay() at the end of update
    is_playing: bool = true,
    play_label: []const u8 = "Pause",
    vol_pct: i64 = 0,
    elapsed_buf: [16]u8 = undefined,
    elapsed_str: []const u8 = "0:00",
};

pub const App = native_sdk.UiApp(Model, Msg);
pub const Effects = App.Effects;

pub const Msg = union(enum) {
    tick_feed: native_sdk.EffectTimer,
    tick_reconnect: native_sdk.EffectTimer,
    tick_theme: native_sdk.EffectTimer,
    got_np: native_sdk.EffectResponse,
    got_state: native_sdk.EffectResponse,
    got_themes: native_sdk.EffectResponse,
    audio_event: native_sdk.EffectAudio,
    toggle_play,
    tune_out,
    vol_up,
    vol_down,
};

// ---------------------------------------------------------------- helpers
fn setStr(buf: []u8, out: *[]const u8, v: []const u8) void {
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    out.* = buf[0..n];
}

fn startStream(model: *Model, fx: *Effects) void {
    fx.playAudio(.{
        .key = keys.audio,
        .path = "",
        .url = api.streamUrl(base),
        .cache_path = "", // stream-only: endless Icecast, no disk cache
        .expected_bytes = 0,
        .on_event = Effects.audioMsg(.audio_event),
    });
    fx.setAudioVolume(model.volume);
    model.transport = .playing;
    model.audio_state = "starting";
}

fn fetchFeed(fx: *Effects) void {
    fx.fetch(.{ .key = keys.fetch_np, .url = api.nowPlaying(base), .on_response = Effects.responseMsg(.got_np) });
    fx.fetch(.{ .key = keys.fetch_state, .url = api.state(base), .on_response = Effects.responseMsg(.got_state) });
}

fn fetchThemes(fx: *Effects) void {
    fx.fetch(.{ .key = keys.fetch_themes, .url = api.themes(base), .on_response = Effects.responseMsg(.got_themes) });
}

fn scheduleReconnect(model: *Model, fx: *Effects) void {
    model.stream_failed = true;
    // 500ms → 60s exponential backoff (ports web/hooks/usePlayer.ts).
    const shift: u5 = @intCast(@min(model.retry, 7));
    const delay: u32 = @min(@as(u32, 500) * (@as(u32, 1) << shift), 60_000);
    model.retry +|= 1;
    fx.startTimer(.{ .key = keys.reconnect, .interval_ms = delay, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reconnect) });
}

// ------------------------------------------------------------------ boot
pub fn boot(model: *Model, fx: *Effects) void {
    startStream(model, fx);
    fetchFeed(fx);
    fetchThemes(fx);
    fx.startTimer(.{ .key = keys.feed_timer, .interval_ms = 5000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_feed) });
    fx.startTimer(.{ .key = keys.theme_timer, .interval_ms = 30_000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_theme) });
}

// ---------------------------------------------------------------- update
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick_feed => |t| {
            if (t.outcome == .fired) fetchFeed(fx);
        },
        .tick_reconnect => |t| {
            if (t.outcome == .fired and model.transport == .playing) startStream(model, fx);
        },
        .tick_theme => |t| {
            if (t.outcome == .fired) fetchThemes(fx);
        },
        .got_np => |r| {
            model.feed_count += 1;
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.NowPlaying, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const np = parsed.value;
            if (np.nowPlaying) |t| {
                if (t.title) |v| setStr(&model.title_buf, &model.title, v);
                if (t.artist) |v| setStr(&model.artist_buf, &model.artist, v);
                if (t.album) |v| setStr(&model.album_buf, &model.album, v);
                if (t.genre) |v| setStr(&model.genre_buf, &model.genre, v);
            }
            if (np.dj) |d| {
                if (d.name) |v| setStr(&model.dj_buf, &model.dj, v);
            }
            if (np.listeners) |l| {
                if (l.current) |c| model.listeners = c;
            }
            // Offline debounce: 4 consecutive offline reads before we believe it.
            if (np.streamOnline) |on| {
                if (on) {
                    model.offline_streak = 0;
                    model.stream_online = true;
                } else {
                    model.offline_streak +|= 1;
                    if (model.offline_streak >= 4) model.stream_online = false;
                }
            }
        },
        .got_state => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.StationState, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            // The active theme id also rides /api/state; the token maps come
            // from /api/themes (got_themes), so nothing to apply here yet.
        },
        .got_themes => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.ThemesPayload, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const p = parsed.value;
            const active = p.active orelse return;
            const list = p.themes orelse return;
            for (list) |t| {
                const id = t.id orelse continue;
                if (!std.mem.eql(u8, id, active)) continue;
                const scheme: color.Scheme = if (t.mode) |m|
                    (if (std.mem.eql(u8, m, "dark")) .dark else .light)
                else
                    .light;
                model.theme_scheme = scheme;
                setStr(&model.theme_id_buf, &model.theme_id, id);
                const d = color.defaults(scheme);
                if (t.tokens) |tk| {
                    model.station_colors = .{
                        .bg = color.resolveOr(tk.@"--bg" orelse "", d.bg),
                        .ink = color.resolveOr(tk.@"--ink" orelse "", d.ink),
                        .muted = color.resolveOr(tk.@"--muted" orelse "", d.muted),
                        .accent = color.resolveOr(tk.@"--accent" orelse "", d.accent),
                        .overlay = color.resolveOr(tk.@"--overlay" orelse "", d.overlay),
                        .soft_border = color.resolveOr(tk.@"--soft-border" orelse "", d.soft_border),
                        .field = color.resolveOr(tk.@"--field" orelse "", d.field),
                    };
                } else {
                    model.station_colors = d;
                }
                break;
            }
        },
        .audio_event => |e| {
            model.audio_state = @tagName(e.kind);
            switch (e.kind) {
                .loaded => {
                    model.stream_failed = false;
                    model.retry = 0;
                },
                .position => {
                    model.elapsed_ms = @intCast(e.position_ms);
                    model.buffering = e.buffering;
                    model.stream_failed = false;
                    model.retry = 0;
                },
                .spectrum => {
                    model.spectrum_events += 1;
                    spectrum.step(&model.band_levels, e.bands[0..], 0.06);
                },
                .failed, .rejected => {
                    if (model.transport == .playing) scheduleReconnect(model, fx);
                },
                .completed => {},
            }
        },
        .toggle_play => {
            switch (model.transport) {
                .stopped => startStream(model, fx),
                .playing => {
                    fx.pauseAudio();
                    model.transport = .paused;
                },
                .paused => {
                    fx.resumeAudio();
                    model.transport = .playing;
                },
            }
        },
        .tune_out => {
            fx.stopAudio();
            model.transport = .stopped;
            model.audio_state = "stopped";
        },
        .vol_up => {
            model.volume = @min(model.volume + 0.1, 1.0);
            fx.setAudioVolume(model.volume);
        },
        .vol_down => {
            model.volume = @max(model.volume - 0.1, 0.0);
            fx.setAudioVolume(model.volume);
        },
    }
    syncDisplay(model);
}

// Recompute the markup-bound display fields from state. One place, called after
// every update, so the view never reads a stale label.
fn syncDisplay(model: *Model) void {
    model.is_playing = model.transport == .playing;
    model.play_label = if (model.transport == .playing) "Pause" else "Play";
    model.vol_pct = @intFromFloat(@round(model.volume * 100));
    const mins = @divTrunc(model.elapsed_ms, 60_000);
    const secs = @mod(@divTrunc(model.elapsed_ms, 1000), 60);
    model.elapsed_str = (if (secs < 10)
        std.fmt.bufPrint(&model.elapsed_buf, "{d}:0{d}", .{ mins, secs })
    else
        std.fmt.bufPrint(&model.elapsed_buf, "{d}:{d}", .{ mins, secs })) catch "0:00";
    // Point the chart-bound slice at the (stable, heap-allocated) band array.
    model.bands = model.band_levels[0..];
}

pub fn initialModel() Model {
    return .{};
}
