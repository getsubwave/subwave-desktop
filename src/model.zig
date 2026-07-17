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
    pub const fetch_schedule: u64 = 27;
    pub const save_settings: u64 = 30;
};

pub const max_themes = 12;
pub const max_shows = 16;

// One row in the schedule/guide list (bound by the <for> in card.native). The
// string slices point into the parallel *_store buffers on the model.
pub const ShowRow = struct {
    name: []const u8 = "",
    topic: []const u8 = "",
    persona: []const u8 = "",
    live: bool = false,
};

pub const Transport = enum { stopped, playing, paused };

// App skin (chrome/layout). Both honor the live station theme; they differ in
// layout markup and material density (see theme.tokensFn). Defined here (not in
// skins.zig) so model has no import cycle with the skin registry.
pub const Skin = enum { card, deck };

// ------------------------------------------------------------------ model
pub const Model = struct {
    // station base URL (runtime-switchable). settings_path is resolved in main()
    // before run; stream_url_buf holds the stable URL fed to the audio effect.
    base_buf: [256]u8 = undefined,
    base: []const u8 = api.default_base,
    stream_url_buf: [256]u8 = undefined,
    settings_path_buf: [768]u8 = undefined,
    settings_path: []const u8 = "",

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

    // skin (read by skins.rootView + theme.tokensFn)
    skin: Skin = .card,

    // transport / audio
    transport: Transport = .playing,
    volume: f32 = boot_volume,
    buffering: bool = false,
    stream_failed: bool = false,
    elapsed_ms: i64 = 0,
    retry: u6 = 0,

    // spectrum visualiser: displayed band levels (0..1); bands() is the
    // chart-bound view.
    band_levels: [spectrum.band_count]f32 = [_]f32{0} ** spectrum.band_count,

    // feed bookkeeping
    offline_streak: u8 = 0,

    // theme (read live by theme.tokensFn)
    station_colors: color.StationColors = color.defaults(.light),
    theme_scheme: color.Scheme = .light,
    theme_id_buf: [64]u8 = undefined,
    theme_id: []const u8 = "classic-light",
    // per-listener theme override ("" = follow the station's active theme) +
    // the catalogue of theme ids captured from /api/themes (for the cycle).
    theme_override_buf: [64]u8 = undefined,
    theme_override: []const u8 = "",
    theme_ids_store: [max_themes][64]u8 = undefined,
    theme_ids: [max_themes][]const u8 = [_][]const u8{""} ** max_themes,
    theme_count: usize = 0,

    // station switcher (TEA text field for the address) + settings scratch.
    // save_inflight/save_dirty serialize fx.writeFile calls: a second save
    // while one is in flight would be rejected (duplicate active key), so it
    // is deferred until the .saved result arrives.
    station_buffer: canvas.TextBuffer(200) = .{},
    settings_json_buf: [640]u8 = undefined,
    save_inflight: bool = false,
    save_dirty: bool = false,

    // schedule / station guide
    show_schedule: bool = false,
    show_names_store: [max_shows][48]u8 = undefined,
    show_topics_store: [max_shows][140]u8 = undefined,
    show_personas_store: [max_shows][40]u8 = undefined,
    show_rows: [max_shows]ShowRow = [_]ShowRow{.{}} ** max_shows,
    show_count: usize = 0,

    // song request (TEA text-field mirror + POST/poll status)
    req_buffer: canvas.TextBuffer(120) = .{},
    req_status: []const u8 = "",
    req_id_buf: [64]u8 = undefined,
    req_id: []const u8 = "",

    // booth ticker: the DJ's latest utterance
    booth_buf: [280]u8 = undefined,
    booth_line: []const u8 = "",

    // ------------------------------------------------- derived view bindings
    // Everything the markup shows that is computable from the state above is a
    // method, never a cached field ("derive, don't store") — so no label can
    // ever be stale, including before the first update runs.

    // The text the request field binds (derived from the edit buffer).
    pub fn req_text(self: *const Model) []const u8 {
        return self.req_buffer.text();
    }
    // The text the station-address field binds.
    pub fn station_text(self: *const Model) []const u8 {
        return self.station_buffer.text();
    }

    pub fn play_label(self: *const Model) []const u8 {
        return if (self.transport == .playing) "Pause" else "Play";
    }

    pub fn play_icon(self: *const Model) []const u8 {
        return if (self.transport == .playing) "pause" else "play";
    }

    pub fn has_genre(self: *const Model) bool {
        return self.genre.len > 0;
    }

    // The muted meta line under the artist: on-air time, then the DJ when known.
    pub fn np_meta(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const elapsed = self.elapsed_str(arena);
        if (self.dj.len == 0)
            return std.fmt.allocPrint(arena, "on air {s}", .{elapsed}) catch "";
        return std.fmt.allocPrint(arena, "on air {s} · DJ {s}", .{ elapsed, self.dj }) catch "";
    }

    pub fn vol_pct(self: *const Model) i64 {
        return @intFromFloat(@round(self.volume * 100));
    }

    // Player-elapsed as m:ss, rolling to h:mm:ss past the hour (radio sessions
    // easily exceed 60 minutes).
    pub fn elapsed_str(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const total_secs: u64 = @intCast(@max(0, @divTrunc(self.elapsed_ms, 1000)));
        const hours = total_secs / 3600;
        const mins = (total_secs / 60) % 60;
        const secs = total_secs % 60;
        if (hours > 0)
            return std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch "0:00";
        return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ mins, secs }) catch "0:00";
    }

    // Transient state banner (priority: failure > buffering > offline > idle).
    pub fn state_line(self: *const Model) []const u8 {
        if (self.stream_failed) return "STREAM LOST — reconnecting…";
        if (self.buffering) return "BUFFERING…";
        if (!self.stream_online) return "OFF AIR";
        return switch (self.transport) {
            .paused => "PAUSED",
            .stopped => "TUNED OUT",
            .playing => "",
        };
    }

    pub fn has_state(self: *const Model) bool {
        return self.state_line().len > 0;
    }

    // Disc initials fallback: up to two leading letters of the artist.
    pub fn initials(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const out = arena.alloc(u8, 2) catch return "◎";
        var n: usize = 0;
        for (self.artist) |ch| {
            if (std.ascii.isAlphabetic(ch)) {
                out[n] = std.ascii.toUpper(ch);
                n += 1;
                if (n >= 2) break;
            }
        }
        if (n == 0) return "◎";
        return out[0..n];
    }

    // Label for the skin-switch button (names the OTHER skin).
    pub fn skin_label(self: *const Model) []const u8 {
        return if (self.skin == .card) "Deck view" else "Card view";
    }

    pub fn has_booth(self: *const Model) bool {
        return self.booth_line.len > 0;
    }

    pub fn theme_label(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.theme_override.len == 0) return "Theme: station";
        return std.fmt.allocPrint(arena, "Theme: {s}", .{self.theme_override}) catch "Theme";
    }

    pub fn showing_now(self: *const Model) bool {
        return !self.show_schedule;
    }

    pub fn schedule_label(self: *const Model) []const u8 {
        return if (self.show_schedule) "Now playing" else "Schedule";
    }

    // The chart-bound spectrum series.
    pub fn bands(self: *const Model) []const f32 {
        return self.band_levels[0..];
    }

    // Schedule rows with the on-air show flagged live.
    pub fn shows_list(self: *const Model, arena: std.mem.Allocator) []const ShowRow {
        const out = arena.alloc(ShowRow, self.show_count) catch return &.{};
        for (out, self.show_rows[0..self.show_count]) |*row, src| {
            row.* = src;
            row.live = self.show.len > 0 and std.mem.eql(u8, src.name, self.show);
        }
        return out;
    }

    // One-word transport status for the status bar.
    pub fn status_word(self: *const Model) []const u8 {
        if (self.stream_failed) return "reconnecting";
        if (self.buffering) return "buffering";
        if (!self.stream_online) return "off air";
        return switch (self.transport) {
            .paused => "paused",
            .stopped => "tuned out",
            .playing => "live",
        };
    }

    // Names read/dispatched only by update/fx (never bound in markup) — opt out
    // of the dead-state lint. Effect-result Msgs, backing buffers, and internal
    // or derived-source state.
    pub const view_unbound = .{
        // fixed backing buffers behind the bound slice fields
        "title_buf",       "artist_buf",     "album_buf",     "genre_buf",
        "dj_buf",          "show_buf",       "cover_sid_buf", "cover_url_buf",
        "theme_id_buf",    "req_id_buf",     "booth_buf",
        // internal / derived-source state
        "skin",            "transport",      "volume",        "buffering",
        "elapsed_ms",      "band_levels",    "req_buffer",    "retry",
        "offline_streak",  "stream_failed",  "stream_online", "cover_sid",
        "next_cover_id",   "req_id",         "theme_scheme",  "station_colors",
        // station / settings / theme-override state
        "base",            "base_buf",       "stream_url_buf", "settings_path",
        "settings_path_buf", "settings_json_buf", "station_buffer",
        "theme_override",  "theme_override_buf",
        "theme_ids",       "theme_ids_store", "theme_count",
        "save_inflight",   "save_dirty",
        // consumed by derived methods (np_meta), not bound directly in markup
        "elapsed_str",     "dj",
        // schedule / guide backing storage
        "show_names_store", "show_topics_store", "show_personas_store",
        "show_rows",        "show_count",
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
    got_schedule: native_sdk.EffectResponse,
    got_reqpost: native_sdk.EffectResponse,
    got_reqstat: native_sdk.EffectResponse,
    tick_reqpoll: native_sdk.EffectTimer,
    saved: native_sdk.EffectFileResult,
    audio_event: native_sdk.EffectAudio,
    toggle_play,
    tune_out,
    vol_up,
    vol_down,
    switch_skin,
    req_edit: canvas.TextInputEvent,
    submit_req,
    station_edit: canvas.TextInputEvent,
    tune_station,
    cycle_theme,
    toggle_schedule,

    // Effect-result Msgs dispatched by the runtime/fx, not markup.
    pub const view_unbound = .{
        "tick_feed",   "tick_reconnect", "tick_theme",  "tick_reqpoll",
        "got_np",      "got_state",      "got_themes",  "got_cover",
        "got_session", "got_reqpost",    "got_reqstat", "audio_event",
        "saved",       "got_schedule",
    };
};

// ---------------------------------------------------------------- helpers
fn setStr(buf: []u8, out: *[]const u8, v: []const u8) void {
    var n = @min(v.len, buf.len);
    // Never truncate mid-codepoint: back off past any UTF-8 continuation bytes
    // so the copy stays valid UTF-8.
    if (n < v.len) {
        while (n > 0 and v[n] & 0xC0 == 0x80) n -= 1;
    }
    @memcpy(buf[0..n], v[0..n]);
    out.* = buf[0..n];
}

fn startStream(model: *Model, fx: *Effects) void {
    // Stream URL lives in a stable model buffer (the audio effect streams from
    // it continuously; a stack buffer could dangle).
    const url = api.streamUrl(&model.stream_url_buf, model.base) catch return;
    fx.playAudio(.{
        .key = keys.audio,
        .path = "",
        .url = url,
        .cache_path = "", // stream-only: endless Icecast, no disk cache
        .expected_bytes = 0,
        .on_event = Effects.audioMsg(.audio_event),
    });
    fx.setAudioVolume(model.volume);
    model.transport = .playing;
}

fn fetchFeed(model: *Model, fx: *Effects) void {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    if (api.nowPlaying(&b1, model.base)) |u| fx.fetch(.{ .key = keys.fetch_np, .url = u, .on_response = Effects.responseMsg(.got_np) }) else |_| {}
    if (api.state(&b2, model.base)) |u| fx.fetch(.{ .key = keys.fetch_state, .url = u, .on_response = Effects.responseMsg(.got_state) }) else |_| {}
    if (api.session(&b3, model.base)) |u| fx.fetch(.{ .key = keys.fetch_session, .url = u, .on_response = Effects.responseMsg(.got_session) }) else |_| {}
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
            // Any other control byte would make the JSON body invalid — drop it.
            0x00...0x09, 0x0b...0x1f => {},
            else => {
                buf[w] = ch;
                w += 1;
            },
        }
    }
    return buf[0..w];
}

fn fetchThemes(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.themes(&b, model.base)) |u| fx.fetch(.{ .key = keys.fetch_themes, .url = u, .on_response = Effects.responseMsg(.got_themes) }) else |_| {}
}

fn fetchSchedule(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.schedule(&b, model.base)) |u| fx.fetch(.{ .key = keys.fetch_schedule, .url = u, .on_response = Effects.responseMsg(.got_schedule) }) else |_| {}
}

// Apply a settings.json blob (called at startup from settings.loadFromDisk).
pub fn applySettingsJson(model: *Model, bytes: []const u8) void {
    const parsed = json.parse(json.Settings, std.heap.page_allocator, bytes) catch return;
    defer parsed.deinit();
    const s = parsed.value;
    if (s.volume) |v| model.volume = std.math.clamp(v, 0.0, 1.0);
    if (s.skin) |sk| model.skin = if (std.mem.eql(u8, sk, "deck")) .deck else .card;
    if (s.themeOverride) |t| setStr(&model.theme_override_buf, &model.theme_override, t);
    if (s.station) |st| {
        if (st.len > 0) {
            if (api.normalizeBase(&model.base_buf, st)) |b| model.base = b else |_| {}
        }
    }
}

// Persist the current settings (async via fx.writeFile). While a write is in
// flight further saves set save_dirty; the .saved result re-saves once, so the
// last state always lands on disk (a concurrent writeFile on the same key
// would be rejected).
fn saveSettings(model: *Model, fx: *Effects) void {
    if (model.settings_path.len == 0) return;
    if (model.save_inflight) {
        model.save_dirty = true;
        return;
    }
    const skin = if (model.skin == .deck) "deck" else "card";
    if (std.fmt.bufPrint(&model.settings_json_buf, "{{\"volume\":{d:.2},\"skin\":\"{s}\",\"themeOverride\":\"{s}\",\"station\":\"{s}\"}}", .{ model.volume, skin, model.theme_override, model.base })) |body| {
        fx.writeFile(.{ .key = keys.save_settings, .path = model.settings_path, .bytes = body, .on_result = Effects.fileMsg(.saved) });
        model.save_inflight = true;
    } else |_| {}
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
    fetchFeed(model, fx);
    fetchThemes(model, fx);
    fetchSchedule(model, fx);
    fx.startTimer(.{ .key = keys.feed_timer, .interval_ms = 5000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_feed) });
    fx.startTimer(.{ .key = keys.theme_timer, .interval_ms = 30_000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_theme) });
}

// ---------------------------------------------------------------- update
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick_feed => |t| {
            if (t.outcome == .fired) fetchFeed(model, fx);
        },
        .tick_reconnect => |t| {
            if (t.outcome == .fired and model.transport == .playing) startStream(model, fx);
        },
        .tick_theme => |t| {
            if (t.outcome == .fired) fetchThemes(model, fx);
        },
        .got_np => |r| {
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
                        if (api.coverUrl(&model.cover_url_buf, model.base, sid)) |url| {
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
            // The active theme id rides /api/state on the 5 s feed cadence; the
            // token maps come from /api/themes (30 s poll). When the station
            // flips its theme, refresh the tokens right away instead of waiting
            // out the slow poll (unless a listener override pins the theme).
            if (parsed.value.theme) |t| {
                if (t.active) |active| {
                    if (model.theme_override.len == 0 and !std.mem.eql(u8, active, model.theme_id)) {
                        fetchThemes(model, fx);
                    }
                }
            }
        },
        .got_themes => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.ThemesPayload, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const p = parsed.value;
            const active = p.active orelse return;
            const list = p.themes orelse return;
            // Capture the theme-id catalogue for the cycle button.
            model.theme_count = 0;
            for (list) |t| {
                const id = t.id orelse continue;
                if (model.theme_count >= max_themes) break;
                setStr(&model.theme_ids_store[model.theme_count], &model.theme_ids[model.theme_count], id);
                model.theme_count += 1;
            }
            // Target = a valid override, else the station's active theme.
            var target = active;
            if (model.theme_override.len > 0) {
                for (list) |t| {
                    if (t.id) |id| {
                        if (std.mem.eql(u8, id, model.theme_override)) {
                            target = model.theme_override;
                            break;
                        }
                    }
                }
            }
            for (list) |t| {
                const id = t.id orelse continue;
                if (!std.mem.eql(u8, id, target)) continue;
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
        .got_schedule => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.SchedulePayload, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const shows = parsed.value.shows orelse return;
            const personas = parsed.value.personas orelse &[_]json.SchedPersona{};
            model.show_count = 0;
            for (shows) |s| {
                if (model.show_count >= max_shows) break;
                const i = model.show_count;
                const name = s.name orelse continue;
                setStr(&model.show_names_store[i], &model.show_rows[i].name, name);
                setStr(&model.show_topics_store[i], &model.show_rows[i].topic, s.topic orelse "");
                // Resolve persona name from personaId.
                var persona_name: []const u8 = "";
                if (s.personaId) |pid| {
                    for (personas) |p| {
                        if (p.id) |id| {
                            if (std.mem.eql(u8, id, pid)) {
                                persona_name = p.name orelse "";
                                break;
                            }
                        }
                    }
                }
                setStr(&model.show_personas_store[i], &model.show_rows[i].persona, persona_name);
                model.show_count += 1;
            }
        },
        .toggle_schedule => model.show_schedule = !model.show_schedule,
        .req_edit => |edit| model.req_buffer.apply(edit),
        .submit_req => {
            const text = model.req_buffer.text();
            if (text.len == 0) {
                model.req_status = "type a song first";
            } else {
                var esc_buf: [200]u8 = undefined;
                var body_buf: [280]u8 = undefined;
                const esc = jsonEscape(&esc_buf, text);
                var req_url_buf: [256]u8 = undefined;
                const req_url = api.request(&req_url_buf, model.base) catch {
                    model.req_status = "bad station url";
                    return;
                };
                if (std.fmt.bufPrint(&body_buf, "{{\"text\":\"{s}\",\"name\":\"Desktop\"}}", .{esc})) |body| {
                    fx.fetch(.{
                        .key = keys.post_request,
                        .method = .POST,
                        .url = req_url,
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
                if (api.requestStatus(&url_buf, model.base, model.req_id)) |url| {
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
                    spectrum.step(&model.band_levels, e.bands[0..], 0.06);
                },
                // An endless Icecast stream never completes naturally — a
                // .completed means the server closed the connection, so it
                // reconnects exactly like a failure.
                .failed, .rejected, .completed => {
                    if (model.transport == .playing) scheduleReconnect(model, fx);
                },
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
                    // If the stream died while paused there is nothing to
                    // resume — reconnect instead.
                    if (model.stream_failed) {
                        startStream(model, fx);
                    } else {
                        fx.resumeAudio();
                        model.transport = .playing;
                    }
                },
            }
        },
        .tune_out => {
            fx.stopAudio();
            model.transport = .stopped;
        },
        .vol_up => {
            model.volume = @min(model.volume + 0.1, 1.0);
            fx.setAudioVolume(model.volume);
            saveSettings(model, fx);
        },
        .vol_down => {
            model.volume = @max(model.volume - 0.1, 0.0);
            fx.setAudioVolume(model.volume);
            saveSettings(model, fx);
        },
        .switch_skin => {
            model.skin = if (model.skin == .card) .deck else .card;
            saveSettings(model, fx);
        },
        .saved => {
            model.save_inflight = false;
            if (model.save_dirty) {
                model.save_dirty = false;
                saveSettings(model, fx);
            }
        },
        .station_edit => |edit| model.station_buffer.apply(edit),
        .tune_station => {
            const raw = model.station_buffer.text();
            if (api.normalizeBase(&model.base_buf, raw)) |b| {
                model.base = b;
                // Re-point everything at the new station: fresh stream + feeds,
                // nothing left over from the old one.
                if (model.cover_id != 0) _ = fx.unregisterImage(model.cover_id);
                model.cover_id = 0;
                model.cover_sid = "";
                model.title = "Tuning in…";
                model.artist = "";
                model.album = "";
                model.genre = "";
                model.dj = "";
                model.show = "";
                model.listeners = 0;
                model.booth_line = "";
                model.show_count = 0;
                model.req_id = "";
                model.req_status = "";
                model.stream_failed = false;
                model.retry = 0;
                fx.cancelTimer(keys.reconnect);
                fx.stopAudio();
                startStream(model, fx);
                fetchFeed(model, fx);
                fetchThemes(model, fx);
                fetchSchedule(model, fx);
                saveSettings(model, fx);
            } else |_| {}
        },
        .cycle_theme => {
            // "" (follow station) → id[0] → id[1] → … → "" .
            if (model.theme_count == 0) {
                // no catalogue yet
            } else if (model.theme_override.len == 0) {
                setStr(&model.theme_override_buf, &model.theme_override, model.theme_ids[0]);
            } else {
                var idx: usize = model.theme_count; // = "not found" sentinel
                for (0..model.theme_count) |i| {
                    if (std.mem.eql(u8, model.theme_ids[i], model.theme_override)) {
                        idx = i;
                        break;
                    }
                }
                if (idx + 1 < model.theme_count) {
                    setStr(&model.theme_override_buf, &model.theme_override, model.theme_ids[idx + 1]);
                } else {
                    model.theme_override = ""; // wrap back to follow-station
                }
            }
            fetchThemes(model, fx); // re-apply with the new override
            saveSettings(model, fx);
        },
    }
}

pub fn initialModel() Model {
    return .{};
}

// -------------------------------------------------------------- tests
const testing = std.testing;

test "elapsed_str rolls to h:mm:ss past the hour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.elapsed_ms = 754_000; // 12:34
    try testing.expectEqualStrings("12:34", m.elapsed_str(arena));
    m.elapsed_ms = 5_025_000; // 1:23:45
    try testing.expectEqualStrings("1:23:45", m.elapsed_str(arena));
    m.elapsed_ms = 9_000; // 0:09
    try testing.expectEqualStrings("0:09", m.elapsed_str(arena));
}

test "initials take the artist's first two letters, with a fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.artist = "the Midnight";
    try testing.expectEqualStrings("TH", m.initials(arena));
    m.artist = "";
    try testing.expectEqualStrings("◎", m.initials(arena));
}

test "state banner priority: failure > buffering > offline > paused" {
    var m: Model = .{};
    try testing.expect(!m.has_state()); // playing + online: no banner
    m.transport = .paused;
    try testing.expectEqualStrings("PAUSED", m.state_line());
    m.stream_online = false;
    try testing.expectEqualStrings("OFF AIR", m.state_line());
    m.buffering = true;
    try testing.expectEqualStrings("BUFFERING…", m.state_line());
    m.stream_failed = true;
    try testing.expectEqualStrings("STREAM LOST — reconnecting…", m.state_line());
}

test "setStr never splits a UTF-8 codepoint on truncation" {
    var buf: [5]u8 = undefined;
    var out: []const u8 = "";
    setStr(&buf, &out, "ab날개"); // 2 + 3 + 3 bytes; byte cut would land mid-'날'
    try testing.expectEqualStrings("ab날", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "jsonEscape escapes quotes and drops raw control bytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("say \\\"hi\\\"\\n", jsonEscape(&buf, "say \"hi\"\n"));
    try testing.expectEqualStrings("ab", jsonEscape(&buf, "a\x01b\r"));
}
