//! The player's heart: Model state, the Msg union, boot (init_fx), and the
//! update reducer that wires every effect. Kept free of view code — main.zig
//! does the App wiring, app.native is the view.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const api = @import("api.zig");
const json = @import("json.zig");
const color = @import("color.zig");
const spectrum = @import("spectrum.zig");

const base = api.default_base;

// Default listening volume on tune-in. (Decode/position/spectrum report
// regardless of output volume; set to 0.0 to boot muted for headless runs.)
pub const boot_volume: f32 = 0.8;

// ---------------------------------------------------------------- effect keys
pub const keys = struct {
    pub const audio: u64 = 10;
    pub const feed_timer: u64 = 1;
    pub const theme_timer: u64 = 2;
    pub const reconnect: u64 = 3;
    pub const request_poll: u64 = 4;
    pub const fetch_np: u64 = 20;
    pub const fetch_state: u64 = 21;
    pub const fetch_themes: u64 = 22;
    pub const fetch_cover: u64 = 23;
    pub const fetch_session: u64 = 24;
    pub const post_request: u64 = 25;
    pub const fetch_reqstat: u64 = 26;
};

pub const Transport = enum { stopped, playing, paused };

// App skin (chrome/layout). Both honor the live station theme; they differ in
// layout markup and material density (see theme.tokensFn). Defined here (not in
// skins.zig) so model has no import cycle with the skin registry.
pub const Skin = enum { card, deck };

// ------------------------------------------------------------------ model
pub const Model = struct {
    // now playing (slices point into the *_buf fixed buffers)
    title_buf: [512]u8 = undefined,
    artist_buf: [256]u8 = undefined,
    album_buf: [256]u8 = undefined,
    genre_buf: [64]u8 = undefined,
    dj_buf: [128]u8 = undefined,
    show_buf: [128]u8 = undefined,
    title: []const u8 = "Tuning in…",
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    dj: []const u8 = "",
    show: []const u8 = "",
    listeners: i64 = 0,
    stream_online: bool = true,

    // cover art (registered image ids; 0 = disc/initials fallback)
    cover_id: u64 = 0,
    next_cover_id: u64 = 1,
    cover_sid_buf: [64]u8 = undefined,
    cover_sid: []const u8 = "",
    cover_url_buf: [256]u8 = undefined,
    initials_buf: [4]u8 = undefined,
    initials: []const u8 = "◎",

    // skin (read by skins.rootView + theme.tokensFn)
    skin: Skin = .card,
    skin_label: []const u8 = "Deck view",

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

    // song request (TEA text-field mirror + POST/poll status)
    req_buffer: canvas.TextBuffer(120) = .{},
    req_status: []const u8 = "",
    req_id_buf: [64]u8 = undefined,
    req_id: []const u8 = "",

    // booth ticker: the DJ's latest utterance
    booth_buf: [280]u8 = undefined,
    booth_line: []const u8 = "",
    has_booth: bool = false,

    // derived display fields, recomputed by syncDisplay() at the end of update
    is_playing: bool = true,
    play_label: []const u8 = "Pause",
    vol_pct: i64 = 0,
    elapsed_buf: [16]u8 = undefined,
    elapsed_str: []const u8 = "0:00",
    state_line: []const u8 = "",
    has_state: bool = false,

    // The text the request field binds (derived from the edit buffer).
    pub fn req_text(self: *const Model) []const u8 {
        return self.req_buffer.text();
    }

    // Names read/dispatched only by update/fx (never bound in markup) — opt out
    // of the dead-state lint. Effect-result Msgs, backing buffers, and internal
    // or derived-source state.
    pub const view_unbound = .{
        // fixed backing buffers behind the bound slice fields
        "title_buf",       "artist_buf",     "album_buf",     "genre_buf",
        "dj_buf",          "show_buf",       "cover_sid_buf", "cover_url_buf",
        "initials_buf",    "theme_id_buf",   "elapsed_buf",   "req_id_buf",
        "booth_buf",
        // internal / derived-source state
        "skin",            "transport",      "volume",        "buffering",
        "feed_count",      "is_playing",     "elapsed_ms",    "spectrum_events",
        "band_levels",     "req_buffer",     "retry",         "offline_streak",
        "stream_failed",   "stream_online",  "cover_sid",     "next_cover_id",
        "req_id",          "theme_scheme",   "station_colors",
    };
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
    got_cover: native_sdk.EffectResponse,
    got_session: native_sdk.EffectResponse,
    got_reqpost: native_sdk.EffectResponse,
    got_reqstat: native_sdk.EffectResponse,
    tick_reqpoll: native_sdk.EffectTimer,
    audio_event: native_sdk.EffectAudio,
    toggle_play,
    tune_out,
    vol_up,
    vol_down,
    switch_skin,
    req_edit: canvas.TextInputEvent,
    submit_req,

    // Effect-result Msgs dispatched by the runtime/fx, not markup.
    pub const view_unbound = .{
        "tick_feed",   "tick_reconnect", "tick_theme",  "tick_reqpoll",
        "got_np",      "got_state",      "got_themes",  "got_cover",
        "got_session", "got_reqpost",    "got_reqstat", "audio_event",
    };
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
    fx.fetch(.{ .key = keys.fetch_session, .url = api.session(base), .on_response = Effects.responseMsg(.got_session) });
}

// Minimal JSON string escape for the request text (quotes/backslashes/newlines).
fn jsonEscape(buf: []u8, s: []const u8) []const u8 {
    var w: usize = 0;
    for (s) |ch| {
        if (w + 2 > buf.len) break;
        switch (ch) {
            '"' => {
                buf[w] = '\\';
                buf[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                buf[w] = '\\';
                buf[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                buf[w] = '\\';
                buf[w + 1] = 'n';
                w += 2;
            },
            '\r', '\t' => {},
            else => {
                buf[w] = ch;
                w += 1;
            },
        }
    }
    return buf[0..w];
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
                // Fetch cover art when the track's subsonic id changes.
                if (t.subsonic_id) |sid| {
                    if (sid.len > 0 and !std.mem.eql(u8, sid, model.cover_sid)) {
                        setStr(&model.cover_sid_buf, &model.cover_sid, sid);
                        if (api.coverUrl(&model.cover_url_buf, base, sid)) |url| {
                            fx.fetch(.{ .key = keys.fetch_cover, .url = url, .on_response = Effects.responseMsg(.got_cover) });
                        } else |_| {}
                    }
                }
            }
            if (np.dj) |d| {
                if (d.name) |v| setStr(&model.dj_buf, &model.dj, v);
            }
            if (np.activeShow) |s| {
                if (s.name) |v| setStr(&model.show_buf, &model.show, v);
            } else {
                model.show = "";
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
        .got_cover => |r| {
            if (r.outcome != .ok or r.status != 200 or r.truncated) return;
            const nid = model.next_cover_id;
            _ = fx.registerImageBytes(nid, r.body) catch return;
            if (model.cover_id != 0) _ = fx.unregisterImage(model.cover_id);
            model.cover_id = nid;
            model.next_cover_id += 1;
        },
        .got_session => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.Session, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            // Booth ticker: the most recent DJ-spoken line (skip internal
            // event/user/segment turns — only role "dj" is on-air speech).
            if (parsed.value.messages) |msgs| {
                var i: usize = msgs.len;
                while (i > 0) {
                    i -= 1;
                    const role = msgs[i].role orelse continue;
                    if (!std.mem.eql(u8, role, "dj")) continue;
                    // Skip the DJ's internal pick reasoning — only on-air speech.
                    if (msgs[i].kind) |k| {
                        if (std.mem.eql(u8, k, "pick")) continue;
                    }
                    if (msgs[i].text) |txt| {
                        if (txt.len > 0) {
                            setStr(&model.booth_buf, &model.booth_line, txt);
                            break;
                        }
                    }
                }
            }
        },
        .req_edit => |edit| model.req_buffer.apply(edit),
        .submit_req => {
            const text = model.req_buffer.text();
            if (text.len == 0) {
                model.req_status = "type a song first";
            } else {
                var esc_buf: [200]u8 = undefined;
                var body_buf: [280]u8 = undefined;
                const esc = jsonEscape(&esc_buf, text);
                if (std.fmt.bufPrint(&body_buf, "{{\"text\":\"{s}\",\"name\":\"Desktop\"}}", .{esc})) |body| {
                    fx.fetch(.{
                        .key = keys.post_request,
                        .method = .POST,
                        .url = api.request(base),
                        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                        .body = body,
                        .on_response = Effects.responseMsg(.got_reqpost),
                    });
                    model.req_status = "sending…";
                    model.req_buffer.clear();
                } else |_| {
                    model.req_status = "request too long";
                }
            }
        },
        .got_reqpost => |r| {
            if (r.outcome != .ok) {
                model.req_status = "request failed";
                return;
            }
            if (r.status == 429) {
                model.req_status = "slow down — try again shortly";
                return;
            }
            if (r.status != 202 and r.status != 200) {
                model.req_status = "request not accepted";
                return;
            }
            const parsed = json.parse(json.RequestPost, std.heap.page_allocator, r.body) catch {
                model.req_status = "queued";
                return;
            };
            defer parsed.deinit();
            if (parsed.value.requestId) |id| {
                setStr(&model.req_id_buf, &model.req_id, id);
                model.req_status = "queued — finding it…";
                fx.startTimer(.{ .key = keys.request_poll, .interval_ms = 2000, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reqpoll) });
            } else {
                model.req_status = "queued";
            }
        },
        .tick_reqpoll => |t| {
            if (t.outcome == .fired and model.req_id.len > 0) {
                var url_buf: [256]u8 = undefined;
                if (api.requestStatus(&url_buf, base, model.req_id)) |url| {
                    fx.fetch(.{ .key = keys.fetch_reqstat, .url = url, .on_response = Effects.responseMsg(.got_reqstat) });
                } else |_| {}
            }
        },
        .got_reqstat => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.RequestStatus, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const st = parsed.value.status orelse "pending";
            if (std.mem.eql(u8, st, "resolved")) {
                model.req_status = "playing soon ✓";
            } else if (std.mem.eql(u8, st, "failed")) {
                model.req_status = "couldn't find that one";
            } else {
                model.req_status = "queued — finding it…";
                // Keep polling until terminal.
                fx.startTimer(.{ .key = keys.request_poll, .interval_ms = 2000, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reqpoll) });
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
        .switch_skin => {
            model.skin = if (model.skin == .card) .deck else .card;
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

    // Transient state banner (priority: failure > buffering > offline > paused).
    if (model.stream_failed) {
        model.state_line = "STREAM LOST — reconnecting…";
        model.has_state = true;
    } else if (model.buffering) {
        model.state_line = "BUFFERING…";
        model.has_state = true;
    } else if (!model.stream_online) {
        model.state_line = "OFF AIR";
        model.has_state = true;
    } else if (model.transport == .paused) {
        model.state_line = "PAUSED";
        model.has_state = true;
    } else if (model.transport == .stopped) {
        model.state_line = "TUNED OUT";
        model.has_state = true;
    } else {
        model.state_line = "";
        model.has_state = false;
    }

    // Disc initials fallback: up to two leading letters of the artist.
    model.initials = initialsFrom(&model.initials_buf, model.artist);

    // Label for the skin-switch button (names the OTHER skin).
    model.skin_label = if (model.skin == .card) "Deck view" else "Card view";

    model.has_booth = model.booth_line.len > 0;
}

fn initialsFrom(buf: []u8, artist: []const u8) []const u8 {
    var n: usize = 0;
    for (artist) |ch| {
        if (std.ascii.isAlphabetic(ch)) {
            buf[n] = std.ascii.toUpper(ch);
            n += 1;
            if (n >= 2) break;
        }
    }
    if (n == 0) return "◎";
    return buf[0..n];
}

pub fn initialModel() Model {
    return .{};
}
