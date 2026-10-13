//! The player's heart: Model state, the Msg union, boot (init_fx), and the
//! update reducer that wires every effect. Kept free of view code — main.zig
//! does the App wiring, views/*.native are the views.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const api = @import("api.zig");
const json = @import("json.zig");
const color = @import("color.zig");
const spectrum = @import("spectrum.zig");
const request_suggestions = @import("request_suggestions.zig");
const polling = @import("polling.zig");
const station_status = @import("station_status.zig");
const stream_format = @import("stream_format.zig");
const station_access = @import("station_access.zig");
const discord_rpc = @import("discord_rpc.zig");
// `update` is the reducer below, so the self-update module needs an alias.
const updater = @import("update.zig");
const links = @import("links.zig");
const diag = @import("diag.zig");
const station_time = @import("station_time.zig");
const station_schedule = @import("station_schedule.zig");
const listener_time = @import("listener_time.zig");
const iso8601 = @import("iso8601.zig");
const utf8 = @import("utf8.zig");
pub const StreamFormat = stream_format.StreamFormat;

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
    pub const signal_timer: u64 = 5;
    pub const second_timer: u64 = 6;
    pub const ob_step_timer: u64 = 7;
    pub const fetch_np: u64 = 20;
    pub const fetch_state: u64 = 21;
    pub const fetch_themes: u64 = 22;
    pub const fetch_session: u64 = 24;
    pub const post_request: u64 = 25;
    pub const fetch_reqstat: u64 = 26;
    pub const fetch_schedule: u64 = 27;
    pub const fetch_health: u64 = 28;
    pub const fetch_dj: u64 = 29;
    pub const fetch_directory: u64 = 32;
    pub const post_beacon: u64 = 33;
    pub const fetch_ob_health: u64 = 34;
    pub const fetch_ob_dj: u64 = 35;
    pub const fetch_like: u64 = 36;
    pub const post_like: u64 = 37;
    pub const post_station_auth: u64 = 38;
    pub const save_settings: u64 = 30;
    pub const save_debounce: u64 = 31;
    pub const discord_rpc_a: u64 = 40;
    pub const discord_rpc_b: u64 = 41;
    pub const discord_retry: u64 = 42;
    pub const fetch_update: u64 = 43;
    pub const update_timer: u64 = 44;
    pub const open_release_spawn: u64 = 45;
    pub const open_support_spawn: u64 = 46;
    pub const copy_clipboard: u64 = 47;
    pub const station_credentials: u64 = 70;
    pub const auth_recheck_timer: u64 = 71;
    pub const post_auth_recheck: u64 = 72;
    pub const fetch_ob_fallback: u64 = 73;
    pub const listener_timer: u64 = 50;
    pub const listener_np_a: u64 = 51;
    pub const listener_state_a: u64 = 52;
    pub const listener_np_b: u64 = 53;
    pub const listener_state_b: u64 = 54;
    pub const listener_session_a: u64 = 55;
    pub const listener_session_b: u64 = 56;
    pub const listener_like_a: u64 = 57;
    pub const listener_like_b: u64 = 58;
    pub const request_return: u64 = 80;
    pub const background_feed_timer: u64 = 81;
    pub const directory_status_timer: u64 = 82;
    // One key per cache slot; only three probes run at once.
    pub const directory_status_base: u64 = 83; // 83–99 inclusive

    // Cover art loads through `fx.loadImage`, where the ImageId IS the effect
    // key — so the id counter has to start clear of every key above or a cover
    // load and, say, the now-playing poll would collide on one key. 1000 leaves
    // room for the keys to grow without anyone having to remember this.
    pub const cover_image_base: u64 = 1000;
    // Persona ids stay above the cover range; its counter wraps below this
    // boundary. Avatar loads mint a new slot id so late results cannot alias.
    pub const persona_image_base: u64 = 1_000_000_000;
};

// One directory probe key per cache slot: a capacity bump must not spill past
// the 80–99 window these keys share with the request and polling timers.
comptime {
    std.debug.assert(keys.directory_status_base + station_status.capacity - 1 <= 99);
}

pub const max_themes = 12;
pub const max_shows = 32;
pub const max_recents = 8;
pub const max_discover = 8;
pub const max_upcoming = 8;
pub const max_history = 10;
pub const max_booth = 16;

// Signal-meter scale: one full ruler width in ms (mirrors web useSignal).
pub const signal_scale_ms: i64 = 250;
const probe_backoff_after: u8 = 3;

// The host identity every track toast reuses, so a new track replaces the
// previous notification instead of stacking (SDK 0.9.1).
pub const track_notification_id = "now-playing";
// The application command the toast's action button sends. `onCommand` in
// main.zig is the other half of this route — a rename on one side without
// the other silently turns the button into a no-op, which is what the
// "notification action routes to the player" test in main.zig guards.
pub const open_player_command = "open-player";

// ------------------------------------------------------------------ enums
pub const Transport = enum { stopped, playing, paused };

/// Which surface the main window shows. Onboarding on first run (no saved
/// station); the player once tuned.
pub const Phase = enum { onboarding, player };

/// The FM-dial stop (section panel). `.live` is the bare stage.
pub const Tab = enum { schedule, timeline, live, booth, request };

/// Back-panel popover stack (none = closed).
pub const Sheet = enum { none, panel, sleep, themes, format, discord };

pub const BoothFilter = enum { all, dj, tracks };

/// Request-slip lifecycle (mirrors the design's idle → pending → done card).
pub const ReqPhase = enum { idle, pending, done, failed };

/// Private-station gate lifecycle (mirrors the web StationGate's
/// checking/prompt/ok phases; .idle = no privacy lock engaged).
pub const AuthGate = enum { idle, checking, prompt, ok };

/// One onboarding health-check step.
pub const StepState = enum { wait, run, ok, fail };

// ------------------------------------------------------------------ rows
// One row in the schedule list. Slices point into the parallel *_store
// buffers on the model.
pub const ShowRow = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    topic: []const u8 = "",
    persona: []const u8 = "",
    persona_slot: ?usize = null,
    guests: []const u8 = "",
};

pub const QueueRow = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    req_by: []const u8 = "", // UP NEXT only: requester name, "" = station pick
    hhmm: []const u8 = "", // PLAYED only: aired-at clock
    played_at_s: ?i64 = null,
    ago: []const u8 = "",
};

pub const BoothTurn = struct {
    hhmm: []const u8 = "",
    text: []const u8 = "",
    kind: []const u8 = "", // "VOICE" | "PICK" | "TRACK"
    is_voice: bool = false, // spoken on-air
    is_track: bool = false, // an aired track line
    stamp_epoch_s: ?i64 = null,
    station_stamp: []const u8 = "",
    is_carried: bool = false,
    is_boundary: bool = false,
    persona: []const u8 = "",
};

pub const StationRef = struct {
    name: []const u8 = "",
    url: []const u8 = "",
};

pub const DiscoverRow = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    sub: []const u8 = "", // "Tucson, AZ · desert rock"
};

pub const Chip = request_suggestions.Chip;

// Sleep-timer options.
pub const SleepOpt = struct {
    min: i64,
    label: []const u8,
};

// Dial stops (derived rows carry the Tab payload for pick_tab). `name` is the
// visible trigger text AND the accessible name — the stops used to render as
// radio-preset abbreviations (SHWS / TML / BTH) that needed a separate label to
// be announceable, which is exactly the redundancy a real word removes.
pub const DialStop = struct {
    name: []const u8,
    tab: Tab,
};

pub const DayTab = struct {
    idx: i64,
    label: []const u8,
};

/// Payload for chrome_changed (hidden-titlebar insets). The window-control
/// cluster lands on the edge its platform puts it on — macOS reports the
/// traffic lights as `leading`, Windows reports min/max/close as `trailing` —
/// so the masthead pads BOTH and the unused edge is honestly zero.
pub const ChromeInsets = struct {
    top: f32 = 0,
    leading: f32 = 0,
    trailing: f32 = 0,
};

// ------------------------------------------------------------------ model
pub const Model = struct {
    // which surface the main window shows
    phase: Phase = .onboarding,

    // station base URL (runtime-switchable). settings_path is resolved in main()
    // before run; stream_url_buf holds the stable URL fed to the audio effect.
    base_buf: [256]u8 = undefined,
    base: []const u8 = api.default_base,
    // Sized for base + mount + a fully percent-encoded station password.
    stream_url_buf: [768]u8 = undefined,
    settings_path_buf: [768]u8 = undefined,
    settings_path: []const u8 = "",
    self_exe_path_buf: [768]u8 = undefined,
    self_exe_path: []const u8 = "",
    // OS per-app cache dir (resolved beside settings_path at startup). Empty
    // means "could not resolve" — cover loads then simply run uncached rather
    // than guessing a path.
    cache_dir_buf: [640]u8 = undefined,
    cache_dir: []const u8 = "",

    // station identity (/api/dj)
    station_name_buf: [48]u8 = undefined,
    station_name: []const u8 = "SUB/WAVE",
    station_loc_buf: [48]u8 = undefined,
    station_loc: []const u8 = "",

    // now playing (slices point into the *_buf fixed buffers)
    // Self-update notice: empty tag = no newer release known.
    update_tag_buf: [24]u8 = undefined,
    update_tag: []const u8 = "",
    opener_inflight: bool = false,

    title_buf: [512]u8 = undefined,
    artist_buf: [256]u8 = undefined,
    album_buf: [256]u8 = undefined,
    genre_buf: [64]u8 = undefined,
    dj_buf: [128]u8 = undefined,
    show_buf: [128]u8 = undefined,
    host_buf: [64]u8 = undefined,
    title: []const u8 = "Tuning in…",
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    dj: []const u8 = "",
    show: []const u8 = "",
    host: []const u8 = "", // active show's persona name
    listeners: i64 = 0,
    stream_online: bool = true,
    track_year: i64 = 0,
    track_duration_s: i64 = 0,
    track_bpm: i64 = 0,
    key_buf: [16]u8 = undefined,
    musical_key: []const u8 = "",
    moods_buf: [96]u8 = undefined,
    moods: []const u8 = "", // pre-joined "NEON · DRIFTING"
    energy_buf: [16]u8 = undefined,
    energy: []const u8 = "",
    llm_tokens: i64 = 0,

    // masthead context line (/now-playing context envelope)
    ctx_show_buf: [48]u8 = undefined,
    ctx_show: []const u8 = "",
    ctx_vibe_buf: [48]u8 = undefined,
    ctx_vibe: []const u8 = "",
    ctx_cond_buf: [32]u8 = undefined,
    ctx_cond: []const u8 = "",
    ctx_temp: i64 = -999, // -999 = unknown
    ctx_festival_store: [96]u8 = undefined,
    ctx_festival: []const u8 = "",

    // cover art (registered image ids; 0 = disc/initials fallback). The art is
    // loaded by `fx.loadImage`, which runs the fetch and the decode on a worker
    // thread and keeps a disk cache, so a track that aired recently comes back
    // without touching the network. `cover_id` is only ever the id of pixels
    // the runtime has confirmed registered; `cover_loading_id` is the one still
    // in flight (0 = none), kept so a new track can cancel the old load.
    cover_id: u64 = 0,
    cover_loading_id: u64 = 0,
    next_cover_id: u64 = keys.cover_image_base,
    cover_sid_buf: [64]u8 = undefined,
    cover_sid: []const u8 = "",
    cover_url_buf: [256]u8 = undefined,
    cover_cache_buf: [832]u8 = undefined,

    // Heartbeat bookkeeping. The audio-event count is the closest honest
    // proxy for "is the loop still turning" (the model has no frame counter,
    // and the audio channel is the ~25 Hz animation clock). It rides the
    // feed poll (tick_feed) as the diagnostic heartbeat, at 5s in foreground
    // and 10s during background playback.
    // NEVER log per event — count here, emit on the tick. See src/diag.zig's
    // header and issue #23.
    hb_audio_events: u32 = 0,
    // Counts fired tick_feed ticks between heartbeat emissions. At 5s/tick, a
    // ~72-byte heartbeat line every tick fills diag's 256 KB cap in about
    // 3640 beats — just over 5 hours — silencing the log long before issue
    // #23's multi-day sessions hang. Emitting only every 12th fired tick
    // slows the heartbeat to 60s, buying roughly 12x the runtime before the
    // cap (now wrapping, not going silent — see diag.zig) is next hit.
    hb_tick_count: u8 = 0,

    // transport / audio
    transport: Transport = .playing,
    volume: f32 = boot_volume,
    // Mute is session-only and orthogonal to volume: the intended `volume`
    // is preserved so unmute restores it; while muted the audio output is 0.
    muted: bool = false,
    // Last slider value accepted by syncModel. Lets the sync
    // tell a genuine drag (the widget moved on its own) apart from the widget
    // replaying a value a model-side write has already moved past. null until
    // the first observation. Rejected noise leaves this baseline unchanged
    // so small drag movements can accumulate. See reconcileVolumeFromWidget.
    volume_widget_seen: ?f32 = null,
    buffering: bool = false,
    stream_failed: bool = false,
    elapsed_ms: i64 = 0,
    retry: u6 = 0,

    // Listener-picked stream format (persisted; MP3 = the default floor) +
    // the optional-mount flags the station last advertised on /now-playing.
    // Pre-first-poll (flags unknown) the stored pick is trusted
    // optimistically — the first poll self-corrects a dead mount to the
    // floor (see effectiveFormat / got_np).
    format_pref: StreamFormat = .mp3,
    stream_flags_known: bool = false,
    stream_opus: bool = false,
    stream_flac: bool = false,
    stream_aac: bool = false,
    // The station's PRIMARY mount and its bitrate, as advertised alongside
    // those flags. The bitrate describes that mount and no other, so the deck
    // chip only prints it while the listener is actually tuned to it —
    // labelling an Opus stream "192k" would be inventing a measurement.
    stream_primary: ?StreamFormat = null,
    stream_bitrate: u32 = 0, // 0 = unknown

    // signal probe (timed GET /api/health while playing)
    latency_ms: i64 = -1, // -1 = no reading yet
    probe_t0: u64 = 0, // monotonic ms at probe fire
    probe_fails: u8 = 0,
    probe_inflight: bool = false,
    probe_slow: bool = false, // true once backed off to the gentle cadence

    // spectrum visualiser: displayed band levels (0..1); bands() is the
    // chart-bound view.
    band_levels: [spectrum.band_count]f32 = [_]f32{0} ** spectrum.band_count,

    // feed bookkeeping
    offline_streak: u8 = 0,
    poll_cadence: polling.Cadence = .{},

    // ------------------------------------------------------------- UI state
    active_tab: Tab = .live,
    sidebar_open: bool = false,
    sheet: Sheet = .none,
    mini_open: bool = false,

    // hidden-titlebar chrome insets (macOS traffic lights lead, Windows
    // min/max/close trails)
    chrome_top: f32 = 0,
    chrome_leading: f32 = 0,
    chrome_trailing: f32 = 0,

    // sleep timer (wall-clock deadline; 0 = off)
    sleep_deadline_ms: i64 = 0,
    sleep_minutes: i64 = 0,
    now_wall_ms: i64 = 0, // refreshed by the shared panel/sleep tick

    // theme (read live by theme.tokensFn)
    station_colors: color.StationColors = color.defaults(.light),
    theme_scheme: color.Scheme = .light,
    theme_id_buf: [64]u8 = undefined,
    theme_id: []const u8 = "classic-light",
    // per-listener theme override ("" = follow the station's active theme) +
    // the catalogue captured from /api/themes (ids + display names).
    theme_override_buf: [64]u8 = undefined,
    theme_override: []const u8 = "",
    theme_ids_store: [max_themes][64]u8 = undefined,
    theme_ids: [max_themes][]const u8 = [_][]const u8{""} ** max_themes,
    theme_names_store: [max_themes][48]u8 = undefined,
    theme_names: [max_themes][]const u8 = [_][]const u8{""} ** max_themes,
    theme_descs_store: [max_themes][96]u8 = undefined,
    theme_descs: [max_themes][]const u8 = [_][]const u8{""} ** max_themes,
    theme_count: usize = 0,

    // Private-station gate (#478, mirrors web StationGate). The flags ride
    // /api/state; the shared password is validated against POST
    // /api/station-auth (which fails closed) and rides the stream URL as
    // ?auth= once accepted. `station_pw` is only ever a password the station
    // confirmed (or the persisted one, re-validated when a lock is seen);
    // `auth_try` is the candidate in flight so a 200 knows what to keep.
    privacy_private: bool = false,
    privacy_listener_auth: bool = false,
    auth_gate: AuthGate = .idle,
    station_pw_buf: [128]u8 = undefined,
    station_pw: []const u8 = "",
    pw_buffer: canvas.TextBuffer(128) = .{},
    auth_try_buf: [128]u8 = undefined,
    auth_try: []const u8 = "",
    auth_from_store: bool = false,
    auth_body_buf: [1024]u8 = undefined, // POST body must outlive the frame
    auth_status: []const u8 = "", // static literals; "" = no error to show
    station_memory: station_access.Memory = .{},
    use_secure_credentials: bool = station_access.secure_credentials_supported,
    keep_station_memory: bool = true,
    credentials_ready: bool = true,
    credentials_blocked: bool = false,
    credentials_saving: bool = false,
    credentials_dirty: bool = false,
    auth_recheck: station_access.Recheck = .{},
    auth_recheck_inflight: bool = false,
    auth_recheck_body_buf: [1024]u8 = undefined,

    // station switcher (TEA text field for the address; shared by the
    // onboarding host field and the sidebar's add-a-station field — the two
    // are never on screen together) + settings scratch.
    station_buffer: canvas.TextBuffer(200) = .{},
    station_status: []const u8 = "",
    settings_json_buf: [station_access.settings_bytes]u8 = undefined,
    save_inflight: bool = false,
    save_dirty: bool = false,

    // Desktop track-change toasts (SDK 0.8.4 fx.showNotification). Opt-in:
    // an existing settings.json carries no notifyTrack key, so an update
    // never starts interrupting a listener who never asked for it.
    notify_track: bool = false,
    // App foreground state, from the app_activated / app_deactivated
    // lifecycle Msgs. Polling and notifications share this focus signal.
    app_active: bool = true,
    main_occluded: bool = false,

    // Discord Rich Presence (opt-in; see discord_rpc.zig / discord.zon).
    discord_enabled: bool = false,
    // Listener-entered Discord application ID (Discord sheet, persisted in
    // settings.json); "" = fall back to the build-time discord.zon default.
    // Whether the feature is configured at all is the derived
    // discord_configured() getter, not a stored flag.
    discord_id_buffer: canvas.TextBuffer(24) = .{},
    discord_client_id_buf: [24]u8 = undefined,
    discord_client_id: []const u8 = "",
    discord_id_status: []const u8 = "", // static literals; "" = nothing to show
    discord_error: []const u8 = "", // static literals mapped from helper ERROR lines
    discord_connected: bool = false,
    discord_retry_count: u6 = 0,
    discord_spawn_key: u64 = keys.discord_rpc_a,
    discord_last_payload_buf: [discord_rpc.activity_request_max]u8 = undefined,
    // Despite the name, this holds the diff *signature* (details/state/
    // url/duration, no elapsed_ms) used to decide whether to respawn — not
    // the full stdin content actually sent. See updateDiscordPresence.
    discord_last_payload: []const u8 = "",
    // The decoder position belongs to the endless stream. Displayed elapsed
    // uses the listener start from /state (or the legacy NP timestamp), then
    // falls back to the decoder delta only when neither stamp is available.
    track_started_at_s: i64 = 0, // nowPlaying.timestamp, 0 = not sent
    track_anchor_ms: i64 = 0, // elapsed_ms snapshot at the last track change
    track_elapsed_ms: i64 = 0,
    listener: listener_time.Controller = .{},
    listener_np_key: u64 = keys.fetch_np,
    listener_state_key: u64 = keys.fetch_state,
    listener_session_key: u64 = keys.fetch_session,
    listener_like_key: u64 = keys.fetch_like,
    listener_fetches: listener_time.FetchSlots = .{},
    listener_generation: u64 = 0,
    listener_like_generation: u64 = 0,
    listener_feed_deferred: bool = false,
    listener_like_deferred: bool = false,
    dj_talking: bool = false,

    // recents (persisted) + discover (community directory)
    recents_name_store: [max_recents][48]u8 = undefined,
    recents_url_store: [max_recents][256]u8 = undefined,
    recents: [max_recents]StationRef = [_]StationRef{.{}} ** max_recents,
    recents_count: usize = 0,
    discover_name_store: [max_discover][48]u8 = undefined,
    discover_url_store: [max_discover][128]u8 = undefined,
    discover_sub_store: [max_discover][64]u8 = undefined,
    discover_rows: [max_discover]DiscoverRow = [_]DiscoverRow{.{}} ** max_discover,
    discover_count: usize = 0,
    directory_status: station_status.Cache = .{},

    // Listener like for the current airing (mirrors web useTrackLike): the
    // heart stays hidden until GET /api/like confirms the station has likes
    // enabled and something likeable is on air, and only fills on server
    // confirmation — no optimistic state.
    like_song_buf: [64]u8 = undefined,
    like_song: []const u8 = "", // subsonic id the like state refers to
    like_body_buf: [96]u8 = undefined, // POST body must outlive the frame
    like_available: bool = false,
    like_liked: bool = false,
    like_pending: bool = false,
    like_count: u32 = 0,

    // schedule / station guide
    timezone_store: [96]u8 = undefined,
    timezone: []const u8 = "",
    station_locale: station_time.Locale = .en_gb,
    station_offset_minutes: i64 = 0,
    station_clock: native_sdk.Clock = .system,
    station_second_timer_active: bool = false,
    day_picked: bool = false,
    slot_topic_open: [24]bool = [_]bool{false} ** 24,
    slot_host_open: [24]bool = [_]bool{false} ** 24,
    now_topic_open: bool = false,
    now_host_open: bool = false,
    host_id_store: [128]u8 = undefined,
    host_id: []const u8 = "",
    now_guests_store: [384]u8 = undefined,
    now_guests: []const u8 = "",
    persona_roster: station_schedule.Roster = .{},
    persona_images: [station_schedule.max_personas]u64 = [_]u64{0} ** station_schedule.max_personas,
    persona_loading: [station_schedule.max_personas]u64 = [_]u64{0} ** station_schedule.max_personas,
    next_persona_id: u64 = keys.persona_image_base,
    persona_url_store: [station_schedule.max_personas][512]u8 = undefined,
    persona_cache_store: [station_schedule.max_personas][832]u8 = undefined,
    show_ids_store: [max_shows][128]u8 = undefined,
    show_guests_store: [max_shows][384]u8 = undefined,
    show_names_store: [max_shows][96]u8 = undefined,
    show_topics_store: [max_shows][2048]u8 = undefined,
    show_personas_store: [max_shows][96]u8 = undefined,
    show_rows: [max_shows]ShowRow = [_]ShowRow{.{}} ** max_shows,
    show_count: usize = 0,
    // 7x24 grid of show indexes (+1; 0 = autopilot/none) + selected day tab
    sched_grid: [7][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** 7,
    day_sel: i64 = 0,

    // timeline (/api/state upcoming + history)
    up_title_store: [max_upcoming][96]u8 = undefined,
    up_artist_store: [max_upcoming][64]u8 = undefined,
    up_req_store: [max_upcoming][32]u8 = undefined,
    upcoming_rows: [max_upcoming]QueueRow = [_]QueueRow{.{}} ** max_upcoming,
    upcoming_count: usize = 0,
    hist_title_store: [max_history][96]u8 = undefined,
    hist_artist_store: [max_history][64]u8 = undefined,
    hist_time_store: [max_history][8]u8 = undefined,
    history_rows: [max_history]QueueRow = [_]QueueRow{.{}} ** max_history,
    history_count: usize = 0,

    // tray now-playing rows ("Title — Artist", "0:52 · on air · 2 listening")
    // — formatted update-side because status-item labels must point at
    // stable memory.
    tray_track_buf: [96]u8 = undefined,
    tray_track: []const u8 = "",
    tray_status_buf: [64]u8 = undefined,
    tray_status: []const u8 = "",

    // booth feed (/api/session turns, newest first) + the ticker line
    booth_time_store: [max_booth][8]u8 = undefined,
    booth_text_store: [max_booth][240]u8 = undefined,
    booth_turns: [max_booth]BoothTurn = [_]BoothTurn{.{}} ** max_booth,
    booth_count: usize = 0,
    booth_persona_store: [max_booth][128]u8 = undefined,
    raw_booth: [listener_time.max_session_turns]listener_time.Turn = [_]listener_time.Turn{.{}} ** listener_time.max_session_turns,
    raw_booth_count: usize = 0,
    booth_filter: BoothFilter = .all,
    booth_buf: [280]u8 = undefined,
    booth_line: []const u8 = "",

    // song request (TEA text-field mirrors + POST/poll lifecycle)
    req_buffer: canvas.TextBuffer(200) = .{},
    req_name_buffer: canvas.TextBuffer(48) = .{},
    req_phase: ReqPhase = .idle,
    req_status: []const u8 = "",
    req_ack_buf: [200]u8 = undefined,
    req_ack: []const u8 = "",
    req_track_title_buf: [96]u8 = undefined,
    req_track_title: []const u8 = "",
    req_track_artist_buf: [64]u8 = undefined,
    req_track_artist: []const u8 = "",
    req_queue_pos: i64 = 0,
    req_id_buf: [64]u8 = undefined,
    req_id: []const u8 = "",
    req_return_allowed: bool = false,
    req_return_armed: bool = false,

    // onboarding
    ob_https: bool = true,
    ob_checking: bool = false, // false = entry form, true = check phase
    ob_steps: [4]StepState = [_]StepState{.wait} ** 4,
    ob_done: bool = false,
    ob_target_url_buf: [256]u8 = undefined,
    ob_target_url: []const u8 = "",
    ob_target_name_buf: [48]u8 = undefined,
    ob_target_name: []const u8 = "",
    ob_diag_buf: [768]u8 = undefined,
    ob_diag: []const u8 = "",
    ob_raw_buf: [64]u8 = undefined,
    ob_raw: []const u8 = "",
    ob_allow_fallback: bool = false,
    ob_tried_https: bool = false,
    ob_from_sidebar: bool = false,
    ob_insecure: bool = false,

    // ------------------------------------------------- derived view bindings
    // Everything the markup shows that is computable from the state above is a
    // method, never a cached field ("derive, don't store").

    // The text the request slip / signed-name / station fields bind.
    pub fn req_text(self: *const Model) []const u8 {
        return self.req_buffer.text();
    }
    pub fn req_name_text(self: *const Model) []const u8 {
        return self.req_name_buffer.text();
    }
    pub fn station_text(self: *const Model) []const u8 {
        return self.station_buffer.text();
    }
    pub fn pw_text(self: *const Model) []const u8 {
        return self.pw_buffer.text();
    }

    /// A privacy lock is engaged and no validated password is on hand — the
    /// lock screen replaces the player (both lock kinds; the web only fully
    /// replaces it for privatePlayer, but one full gate is simpler and errs
    /// on the private side).
    pub fn station_locked(self: *const Model) bool {
        return (self.privacy_private or self.privacy_listener_auth) and self.auth_gate != .ok;
    }
    pub fn auth_checking(self: *const Model) bool {
        return self.auth_gate == .checking;
    }
    pub fn has_auth_status(self: *const Model) bool {
        return self.auth_status.len > 0;
    }

    pub fn play_label(self: *const Model) []const u8 {
        return if (self.transport == .playing) "Pause" else "Play";
    }
    pub fn play_icon(self: *const Model) []const u8 {
        return if (self.transport == .playing) "pause" else "play";
    }

    pub fn live_now(self: *const Model) bool {
        return self.transport == .playing and !self.stream_failed and !self.buffering and self.stream_online;
    }
    /// Background-only, on-air-only, and never the first fill: the whole
    /// track-toast decision. Kept pure because `fx.showNotification` is
    /// inert and unrecorded under fake execution — there is no
    /// `notificationState()` to assert on — so this predicate is the only
    /// part of the feature a test can actually see.
    pub fn shouldNotifyTrack(self: *const Model) bool {
        return self.notify_track and !self.app_active and self.live_now() and self.has_track();
    }
    /// The toast itself, as data. `fx.showNotification` stays inert under
    /// fake execution, so building the options here — rather than inline at
    /// the call site — is what makes the id and the action assertable;
    /// `shouldNotifyTrack` decides *whether*, this decides *what*.
    pub fn trackNotification(self: *const Model) native_sdk.NotificationOptions {
        return .{
            // One stable id for the whole session: SDK 0.9.1 replaces the
            // notification carrying this id, so a busy hour leaves one
            // current toast in the centre instead of a stack of stale ones.
            .id = track_notification_id,
            // Every platform draws the app name as the notification header
            // itself, so the title slot carries the track, not "SUBWAVE".
            .title = self.title,
            .subtitle = self.artist,
            .body = self.show,
            // Paired fields — the SDK drops the whole notification if only
            // one is set. The command is an ordinary application command,
            // the same one the tray's "Open player" item sends.
            .action_label = "Open Player",
            .action_command = open_player_command,
        };
    }
    /// Between tune-in and audio: the power button's spinner state.
    pub fn connecting(self: *const Model) bool {
        return self.transport == .playing and (self.buffering or self.stream_failed);
    }
    pub fn tune_label(self: *const Model) []const u8 {
        return if (self.transport == .stopped) "Tune in" else "Tune out";
    }

    pub fn has_show(self: *const Model) bool {
        return self.show.len > 0;
    }
    pub fn has_host(self: *const Model) bool {
        return self.host.len > 0;
    }
    pub fn show_upper(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return asciiUpper(arena, self.show);
    }
    pub fn host_upper(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return asciiUpper(arena, self.host);
    }

    /// Masthead context line: "graveyard shift · slow burn · 12° clear".
    pub fn ctx_meta(self: *const Model, arena: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        appendPart(&out, arena, self.ctx_show);
        appendPart(&out, arena, self.ctx_vibe);
        if (self.ctx_temp != -999 and self.ctx_cond.len > 0) {
            const s = std.fmt.allocPrint(arena, "{d}° {s}", .{ self.ctx_temp, self.ctx_cond }) catch "";
            appendPart(&out, arena, s);
        } else {
            appendPart(&out, arena, self.ctx_cond);
        }
        return out.items;
    }
    pub fn has_ctx(self: *const Model) bool {
        return self.ctx_show.len > 0 or self.ctx_vibe.len > 0 or self.ctx_cond.len > 0;
    }

    /// "NOW PLAYING — 2:34 / 5:24" head (duration omitted when unknown).
    pub fn np_head(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const elapsed = self.elapsed_str(arena);
        if (self.track_duration_s > 0) {
            const dur = fmtSecs(arena, self.track_duration_s);
            return std.fmt.allocPrint(arena, "NOW PLAYING — {s} / {s}", .{ elapsed, dur }) catch "NOW PLAYING";
        }
        return std.fmt.allocPrint(arena, "NOW PLAYING — {s}", .{elapsed}) catch "NOW PLAYING";
    }
    pub fn has_tokens(self: *const Model) bool {
        return self.llm_tokens > 0;
    }

    /// " · Album · 1998" tail after the artist (parts that exist).
    pub fn album_line(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.album.len == 0 and self.track_year == 0) return "";
        if (self.album.len > 0 and self.track_year > 0)
            return std.fmt.allocPrint(arena, " · {s} · {d}", .{ self.album, self.track_year }) catch "";
        if (self.album.len > 0)
            return std.fmt.allocPrint(arena, " · {s}", .{self.album}) catch "";
        return std.fmt.allocPrint(arena, " · {d}", .{self.track_year}) catch "";
    }

    /// "AMBIENT DUB · 92 BPM · A MIN" — genre/bpm/key, whichever exist.
    pub fn meta_line(self: *const Model, arena: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        appendPart(&out, arena, asciiUpper(arena, self.genre));
        if (self.track_bpm > 0) {
            const s = std.fmt.allocPrint(arena, "{d} BPM", .{self.track_bpm}) catch "";
            appendPart(&out, arena, s);
        }
        appendPart(&out, arena, asciiUpper(arena, self.musical_key));
        return out.items;
    }
    pub fn has_meta(self: *const Model) bool {
        return self.genre.len > 0 or self.track_bpm > 0 or self.musical_key.len > 0;
    }

    /// "NEON · DRIFTING · MID ENERGY" — moods + energy.
    pub fn mood_line(self: *const Model, arena: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        appendPart(&out, arena, asciiUpper(arena, self.moods));
        if (self.energy.len > 0) {
            const s = std.fmt.allocPrint(arena, "{s} ENERGY", .{asciiUpper(arena, self.energy)}) catch "";
            appendPart(&out, arena, s);
        }
        return out.items;
    }
    pub fn has_mood(self: *const Model) bool {
        return self.moods.len > 0 or self.energy.len > 0;
    }
    /// Whether the stage draws the meta/mood paragraph at all.
    pub fn has_meta_or_mood(self: *const Model) bool {
        return self.has_meta() or self.has_mood();
    }
    /// The dash between the meta run and the mood run — empty unless BOTH
    /// sides are there, so the stage can lay the paragraph out as three
    /// unconditional spans (an empty span contributes nothing) instead of
    /// branching the separator into the markup.
    pub fn meta_mood_sep(self: *const Model) []const u8 {
        return if (self.has_meta() and self.has_mood()) " — " else "";
    }

    pub fn vol_pct(self: *const Model) i64 {
        return @intFromFloat(@round(self.volume * 100));
    }
    pub fn vol_display(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.muted) return "Muted";
        return std.fmt.allocPrint(arena, "{d}%", .{self.vol_pct()}) catch "—";
    }
    pub fn mute_label(self: *const Model) []const u8 {
        return if (self.muted) "Unmute" else "Mute";
    }

    // Widget-reported slider values carry float noise (0.39999992 for 0.4),
    // ~1e-6 off. This threshold filters rounding noise; smaller pointer
    // movements accumulate against the last accepted value.
    const volume_widget_epsilon: f32 = 5e-4;

    /// `Options.sync` runs before every build, and it used to mirror the
    /// slider's value into `volume` unconditionally — which meant a model-side
    /// write (vol_up/vol_down, a settings load) was overwritten by the
    /// slider's still-stale value before any build could render the move, so
    /// keyboard volume silently did nothing. Adopt the widget's value only
    /// when the WIDGET moved past the last accepted value; otherwise leave
    /// `volume` alone and let the build push it out to the slider, which the SDK
    /// documents as following its bound source whenever that source moves.
    ///
    /// Pure, and takes a plain f32 rather than the layout tree, so the
    /// decision is unit-testable without building a canvas.WidgetLayoutTree.
    pub fn reconcileVolumeFromWidget(self: *Model, widget_value: f32) void {
        const w = std.math.clamp(widget_value, 0.0, 1.0);
        const moved = if (self.volume_widget_seen) |seen|
            @abs(seen - w) > volume_widget_epsilon
        else
            true;
        if (moved) {
            self.volume = w;
            self.volume_widget_seen = w;
        }
    }

    // Track-elapsed as m:ss, rolling to h:mm:ss past the hour (long mixes).
    pub fn elapsed_str(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return fmtSecs(arena, @max(0, @divTrunc(self.track_elapsed_ms, 1000)));
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

    // Disc initials fallback: up to two leading letters of the artist
    // ("SW" house mark before the first track lands — the bundled face has
    // no ◎ glyph, so a symbol fallback would render tofu).
    pub fn initials(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const out = arena.alloc(u8, 2) catch return "SW";
        var n: usize = 0;
        for (self.artist) |ch| {
            if (std.ascii.isAlphabetic(ch)) {
                out[n] = std.ascii.toUpper(ch);
                n += 1;
                if (n >= 2) break;
            }
        }
        if (n == 0) return "SW";
        return out[0..n];
    }

    pub fn has_booth(self: *const Model) bool {
        return self.booth_line.len > 0;
    }

    /// Whether real cover pixels are registered. 0 is the no-image sentinel,
    /// and `<image>` draws nothing for it — the stage swaps in the initials
    /// disc instead, which is honest both before the first load and after a
    /// failed one.
    pub fn has_cover(self: *const Model) bool {
        return self.cover_id != 0;
    }
    /// A real track is on the deck (not the "Tuning in…" placeholder), so
    /// there is something worth copying.
    pub fn has_track(self: *const Model) bool {
        return self.title.len != 0 and !std.mem.eql(u8, self.title, "Tuning in…");
    }

    // ------------------------------------------------------- signal meter
    pub fn signal_label(self: *const Model) []const u8 {
        if (!self.stream_online) return "Off air";
        if (self.transport == .stopped) return "Standby";
        if (self.connecting()) return "Acquiring";
        if (self.probe_fails >= probe_backoff_after) return "Poor";
        if (self.latency_ms < 0) return "Acquiring";
        if (self.latency_ms <= signal_scale_ms) return "Good";
        return "Fair";
    }
    pub fn signal_readout(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.transport == .stopped) return "—";
        if (self.latency_ms < 0)
            return std.fmt.allocPrint(arena, "{d} listening", .{self.listeners}) catch "—";
        return std.fmt.allocPrint(arena, "{d} listening · {d} ms", .{ self.listeners, self.latency_ms }) catch "—";
    }
    /// 0..1 fraction for the signal progress rail.
    pub fn signal_frac(self: *const Model) f32 {
        if (self.transport == .stopped or self.latency_ms < 0) return 0.02;
        const clamped = @min(self.latency_ms, signal_scale_ms);
        return @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(signal_scale_ms));
    }

    // ------------------------------------------------------------ UI derived
    pub fn panel_open(self: *const Model) bool {
        return self.active_tab != .live;
    }
    pub fn tab_shows(self: *const Model) bool {
        return self.active_tab == .schedule;
    }
    pub fn tab_timeline(self: *const Model) bool {
        return self.active_tab == .timeline;
    }
    pub fn tab_booth(self: *const Model) bool {
        return self.active_tab == .booth;
    }
    pub fn tab_request(self: *const Model) bool {
        return self.active_tab == .request;
    }
    pub fn panel_title(self: *const Model) []const u8 {
        return switch (self.active_tab) {
            .schedule => "Shows",
            .timeline => "Timeline",
            .booth => "The booth",
            .request => "Make a request",
            .live => "",
        };
    }
    pub fn panel_sub(self: *const Model) []const u8 {
        return switch (self.active_tab) {
            .schedule => "weekly schedule",
            .timeline => "the dial, in order",
            .booth => "DJ on the mic",
            .request => "to the booth",
            .live => "",
        };
    }

    pub fn sheet_panel(self: *const Model) bool {
        return self.sheet == .panel;
    }
    pub fn sheet_sleep(self: *const Model) bool {
        return self.sheet == .sleep;
    }
    pub fn sheet_themes(self: *const Model) bool {
        return self.sheet == .themes;
    }
    pub fn sheet_format(self: *const Model) bool {
        return self.sheet == .format;
    }
    pub fn sheet_discord(self: *const Model) bool {
        return self.sheet == .discord;
    }

    // ------------------------------------------------------------ sleep timer
    pub fn sleep_armed(self: *const Model) bool {
        return self.sleep_deadline_ms > 0;
    }
    fn sleepRemainingS(self: *const Model) i64 {
        if (self.sleep_deadline_ms == 0) return 0;
        return @max(0, @divTrunc(self.sleep_deadline_ms - self.now_wall_ms, 1000));
    }
    pub fn sleep_countdown(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return fmtSecs(arena, self.sleepRemainingS());
    }
    pub fn sleep_value(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!self.sleep_armed()) return "Off";
        return std.fmt.allocPrint(arena, "{s} left", .{fmtSecs(arena, self.sleepRemainingS())}) catch "armed";
    }

    // ---------------------------------------------------------------- discord
    /// The ID the helper actually handshakes with: the listener-entered one
    /// wins, the build-time discord.zon constant is the default.
    pub fn effectiveDiscordClientId(self: *const Model) []const u8 {
        return if (self.discord_client_id.len > 0) self.discord_client_id else discord_rpc.client_id;
    }
    pub fn discord_configured(self: *const Model) bool {
        return self.effectiveDiscordClientId().len > 0;
    }
    pub fn has_own_discord_id(self: *const Model) bool {
        return self.discord_client_id.len > 0;
    }
    pub fn discord_id_text(self: *const Model) []const u8 {
        return self.discord_id_buffer.text();
    }
    pub fn has_discord_id_status(self: *const Model) bool {
        return self.discord_id_status.len > 0;
    }

    pub fn discord_row_value(self: *const Model) []const u8 {
        if (!self.discord_configured()) return "Not configured";
        return if (self.discord_enabled) "On" else "Off";
    }

    pub fn discord_status_line(self: *const Model) []const u8 {
        if (!self.discord_enabled) return "";
        if (self.discord_connected) return "Connected";
        if (self.discord_error.len > 0) return self.discord_error;
        return "Waiting for Discord…";
    }

    // ------------------------------------------------------------- catalogues
    pub fn chips(self: *const Model, arena: std.mem.Allocator) []const Chip {
        return request_suggestions.build(arena, .{
            .artist = self.artist,
            .festival = self.ctx_festival,
            .vibe = self.ctx_vibe,
            .show = self.ctx_show,
            .weather = self.ctx_cond,
        });
    }

    pub fn stations_shortcut(_: *const Model) []const u8 {
        return if (builtin.os.tag == .macos) "Cmd K" else "Ctrl K";
    }
    pub fn mini_shortcut(_: *const Model) []const u8 {
        return if (builtin.os.tag == .macos) "Cmd Shift M" else "Ctrl Shift M";
    }

    pub const sleep_options = [_]SleepOpt{
        .{ .min = 15, .label = "15 minutes" },
        .{ .min = 30, .label = "30 minutes" },
        .{ .min = 45, .label = "45 minutes" },
        .{ .min = 60, .label = "60 minutes" },
        .{ .min = 90, .label = "90 minutes" },
    };

    // Uppercase is authored, not styled — the toolkit has no text-transform,
    // and this matches the masthead's KLAIR RADIO / WITH HEER register.
    pub const dial_stops = [_]DialStop{
        .{ .name = "SHOWS", .tab = .schedule },
        .{ .name = "TIMELINE", .tab = .timeline },
        .{ .name = "LIVE", .tab = .live },
        .{ .name = "BOOTH", .tab = .booth },
        .{ .name = "REQUEST", .tab = .request },
    };

    pub const day_tabs = [_]DayTab{
        .{ .idx = 0, .label = "SUN" }, .{ .idx = 1, .label = "MON" },
        .{ .idx = 2, .label = "TUE" }, .{ .idx = 3, .label = "WED" },
        .{ .idx = 4, .label = "THU" }, .{ .idx = 5, .label = "FRI" },
        .{ .idx = 6, .label = "SAT" },
    };

    // ------------------------------------------------------------- schedule
    pub const SlotRow = struct {
        hour: i64 = 0,
        range: []const u8 = "",
        show_name: []const u8 = "",
        persona: []const u8 = "",
        initials: []const u8 = "", // persona initials for the row avatar
        has_host: bool = false,
        on_air: bool = false, // this range contains the station's current hour
        autopilot: bool = false,
        avatar_id: u64 = 0,
        topic: []const u8 = "",
        has_topic: bool = false,
        topic_long: bool = false,
        topic_action: []const u8 = "MORE",
        tagline: []const u8 = "",
        soul: []const u8 = "",
        has_tagline: bool = false,
        has_soul: bool = false,
        host_open: bool = false,
        host_action: []const u8 = "ABOUT",
        guests: []const u8 = "",
        has_guests: bool = false,
    };

    pub fn stationClock(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return formatStationStamp(arena, @divFloor(self.station_clock.wallMs(), 1000), self.station_offset_minutes, self.station_locale, false);
    }

    pub fn stationDay(self: *const Model) i64 {
        return station_time.parts(self.station_clock.wallMs(), self.station_offset_minutes).day;
    }

    pub fn selectedDay(self: *const Model) i64 {
        return if (self.day_picked) self.day_sel else self.stationDay();
    }

    pub fn has_timezone(self: *const Model) bool {
        return self.timezone.len > 0;
    }

    /// The selected day's grid compressed to contiguous ranges.
    pub fn day_slots(self: *const Model, arena: std.mem.Allocator) []const SlotRow {
        const wall_ms = self.station_clock.wallMs();
        const selected_day = if (self.day_picked) self.day_sel else station_time.parts(wall_ms, self.station_offset_minutes).day;
        const d: usize = @intCast(std.math.clamp(selected_day, 0, 6));
        const grid = self.sched_grid[d];
        var out: std.ArrayList(SlotRow) = .empty;
        var h: usize = 0;
        while (h < 24) {
            const v = grid[h];
            var end = h + 1;
            while (end < 24 and grid[end] == v) end += 1;
            var range_buf: [48]u8 = undefined;
            const range = arena.dupe(u8, station_time.hourRange(&range_buf, h, end, self.station_locale)) catch "";
            const on_air = station_time.isNow(wall_ms, self.station_offset_minutes, @intCast(d), h, end);
            if (v == 0) {
                out.append(arena, .{ .hour = @intCast(h), .range = range, .show_name = "Autopilot", .autopilot = true, .on_air = on_air }) catch return out.items;
            } else {
                const idx: usize = v - 1;
                if (idx < self.show_count) {
                    const row = self.show_rows[idx];
                    const p: station_schedule.Persona = if (row.persona_slot) |pi| self.persona_roster.rows[pi] else .{};
                    out.append(arena, .{
                        .hour = @intCast(h),
                        .range = range,
                        .show_name = row.name,
                        .persona = row.persona,
                        .initials = wordInitials(arena, row.persona),
                        .has_host = row.persona.len > 0,
                        .on_air = on_air,
                        .avatar_id = if (row.persona_slot) |pi| self.persona_images[pi] else 0,
                        .topic = if (self.slot_topic_open[h]) row.topic else utf8.prefix(row.topic, 120),
                        .has_topic = row.topic.len > 0,
                        .topic_long = row.topic.len > 120,
                        .topic_action = if (self.slot_topic_open[h]) "LESS" else "MORE",
                        .tagline = p.tagline,
                        .soul = p.soul,
                        .has_tagline = p.tagline.len > 0,
                        .has_soul = p.soul.len > 0,
                        .host_open = self.slot_host_open[h],
                        .host_action = if (self.slot_host_open[h]) "LESS ABOUT" else "ABOUT",
                        .guests = row.guests,
                        .has_guests = row.guests.len > 0,
                    }) catch return out.items;
                }
            }
            h = end;
        }
        return out.items;
    }

    pub const NowShow = struct {
        topic: []const u8 = "",
        has_topic: bool = false,
        topic_long: bool = false,
        topic_action: []const u8 = "MORE",
        tagline: []const u8 = "",
        soul: []const u8 = "",
        has_tagline: bool = false,
        has_soul: bool = false,
        host_open: bool = false,
        host_action: []const u8 = "ABOUT",
        guests: []const u8 = "",
        has_guests: bool = false,
        avatar_id: u64 = 0,
        initials: []const u8 = "",
    };

    pub fn nowShow(self: *const Model, arena: std.mem.Allocator) NowShow {
        var topic: []const u8 = "";
        const time = station_time.parts(self.station_clock.wallMs(), self.station_offset_minutes);
        const slot = self.sched_grid[@intCast(time.day)][@intCast(time.hour)];
        if (slot > 0 and slot <= self.show_count and std.mem.eql(u8, self.show_rows[slot - 1].name, self.show)) {
            topic = self.show_rows[slot - 1].topic;
        } else {
            for (self.show_rows[0..self.show_count]) |row| {
                if (std.mem.eql(u8, row.name, self.show)) {
                    topic = row.topic;
                    break;
                }
            }
        }
        const pi = self.persona_roster.find(self.host_id);
        const p: station_schedule.Persona = if (pi) |i| self.persona_roster.rows[i] else .{};
        return .{
            .topic = if (self.now_topic_open) topic else utf8.prefix(topic, 180),
            .has_topic = topic.len > 0,
            .topic_long = topic.len > 180,
            .topic_action = if (self.now_topic_open) "LESS" else "MORE",
            .tagline = p.tagline,
            .soul = p.soul,
            .has_tagline = p.tagline.len > 0,
            .has_soul = p.soul.len > 0,
            .host_open = self.now_host_open,
            .host_action = if (self.now_host_open) "LESS ABOUT" else "ABOUT",
            .guests = self.now_guests,
            .has_guests = self.now_guests.len > 0,
            .avatar_id = if (pi) |i| self.persona_images[i] else 0,
            .initials = wordInitials(arena, self.host),
        };
    }

    pub fn now_show_list(self: *const Model, arena: std.mem.Allocator) []const NowShow {
        const out = arena.alloc(NowShow, 1) catch return &.{};
        out[0] = self.nowShow(arena);
        return out;
    }

    pub fn has_station_loc(self: *const Model) bool {
        return self.station_loc.len > 0;
    }

    // ------------------------------------------------------------- timeline
    pub const UpRow = struct {
        n: []const u8 = "",
        title: []const u8 = "",
        artist: []const u8 = "",
        req_by: []const u8 = "",
        has_req: bool = false,
    };
    pub fn upcoming_list(self: *const Model, arena: std.mem.Allocator) []const UpRow {
        const out = arena.alloc(UpRow, self.upcoming_count) catch return &.{};
        for (out, self.upcoming_rows[0..self.upcoming_count], 0..) |*row, src, i| {
            row.* = .{
                .n = std.fmt.allocPrint(arena, "{d:0>2}", .{i + 1}) catch "",
                .title = src.title,
                .artist = src.artist,
                .req_by = src.req_by,
                .has_req = src.req_by.len > 0,
            };
        }
        return out;
    }
    pub fn history_list(self: *const Model, arena: std.mem.Allocator) []const QueueRow {
        const out = arena.dupe(QueueRow, self.history_rows[0..self.history_count]) catch return &.{};
        for (out) |*row| {
            row.hhmm = formatStationStamp(arena, row.played_at_s, self.station_offset_minutes, self.station_locale, false);
            if (row.played_at_s) |at| {
                var buf: [48]u8 = undefined;
                row.ago = arena.dupe(u8, station_time.ago(&buf, self.station_clock.wallMs(), at)) catch "";
            }
        }
        return out;
    }

    // ---------------------------------------------------------------- booth
    pub const FilterRow = struct {
        label: []const u8 = "",
        val: BoothFilter = .all,
        on: bool = false,
    };
    pub fn booth_filter_rows(self: *const Model, arena: std.mem.Allocator) []const FilterRow {
        const out = arena.alloc(FilterRow, 3) catch return &.{};
        out[0] = .{ .label = "ALL", .val = .all, .on = self.booth_filter == .all };
        out[1] = .{ .label = "DJ", .val = .dj, .on = self.booth_filter == .dj };
        out[2] = .{ .label = "TRACKS", .val = .tracks, .on = self.booth_filter == .tracks };
        return out;
    }
    pub fn presentation_artist(self: *const Model) []const u8 {
        // Mobile swaps to the show's persona only; with no host the track
        // artist stays.
        if (self.dj_talking and self.host.len > 0) return self.host;
        return self.artist;
    }

    pub fn booth_list(self: *const Model, arena: std.mem.Allocator) []const BoothTurn {
        var out: std.ArrayList(BoothTurn) = .empty;
        for (self.booth_turns[0..self.booth_count]) |t| {
            const keep = switch (self.booth_filter) {
                .all => true,
                .dj => !t.is_track or t.is_boundary,
                .tracks => t.is_track or t.is_boundary,
            };
            if (keep) {
                var row = t;
                row.station_stamp = formatStationStamp(arena, row.stamp_epoch_s, self.station_offset_minutes, self.station_locale, true);
                out.append(arena, row) catch break;
            }
        }
        return out.items;
    }

    // ------------------------------------------------------- update notice
    pub fn update_available(self: *const Model) bool {
        return self.update_tag.len > 0;
    }
    pub fn update_value(self: *const Model) []const u8 {
        return self.update_tag;
    }
    pub fn app_version(self: *const Model) []const u8 {
        _ = self;
        return updater.version;
    }
    pub fn log_dir_value(self: *const Model) []const u8 {
        _ = self;
        return diag.dir();
    }

    // -------------------------------------------------------------- request
    pub fn req_idle(self: *const Model) bool {
        return self.req_phase == .idle;
    }
    pub fn req_pending(self: *const Model) bool {
        return self.req_phase == .pending;
    }
    pub fn req_done(self: *const Model) bool {
        return self.req_phase == .done;
    }
    pub fn req_failed(self: *const Model) bool {
        return self.req_phase == .failed;
    }
    pub fn req_state_label(self: *const Model) []const u8 {
        return switch (self.req_phase) {
            .pending => "ON THE WIRE",
            .done => "QUEUED",
            .failed => "NO DICE",
            .idle => "",
        };
    }
    pub fn req_card_label(self: *const Model) []const u8 {
        return switch (self.req_phase) {
            .pending => "THE DJ IS DIGGING",
            .done => "NOW IN THE BOOTH",
            .failed => "FROM THE BOOTH",
            .idle => "",
        };
    }
    pub fn req_footnote(self: *const Model) []const u8 {
        return switch (self.req_phase) {
            .pending => "YOU CAN CLOSE THIS — YOUR REQUEST IS LOCKED IN",
            .done => "LOCKED IN — LISTEN FOR YOUR SHOUT-OUT",
            else => "",
        };
    }
    pub fn req_ack_line(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.req_ack.len > 0) return self.req_ack;
        const name = std.mem.trim(u8, self.req_name_buffer.text(), " ");
        if (name.len > 0)
            return std.fmt.allocPrint(arena, "Got it, {s} — taking it to the booth.", .{name}) catch "Got it — taking it to the booth.";
        return "Got it — taking it to the booth.";
    }
    pub fn has_req_track(self: *const Model) bool {
        return self.req_track_title.len > 0;
    }
    pub fn has_req_pos(self: *const Model) bool {
        return self.req_queue_pos > 0;
    }
    pub fn has_req_status(self: *const Model) bool {
        return self.req_status.len > 0;
    }

    // ------------------------------------------------------------- stations
    pub const StationStatusRow = struct {
        name: []const u8,
        url: []const u8,
        sub: []const u8 = "",
        live_label: []const u8 = "",
        live_online: bool = false,
    };
    pub fn recents_list(self: *const Model, arena: std.mem.Allocator) []const StationStatusRow {
        const rows = arena.alloc(StationStatusRow, self.recents_count) catch return &.{};
        for (rows, self.recents[0..self.recents_count]) |*row, ref| {
            const status = self.directory_status.find(ref.url);
            row.* = .{ .name = ref.name, .url = ref.url, .live_label = if (status) |s| s.label() else "", .live_online = if (status) |s| s.online else false };
        }
        return rows;
    }
    pub fn has_recents(self: *const Model) bool {
        return self.recents_count > 0;
    }
    pub fn discover_list(self: *const Model, arena: std.mem.Allocator) []const StationStatusRow {
        const rows = arena.alloc(StationStatusRow, self.discover_count) catch return &.{};
        for (rows, self.discover_rows[0..self.discover_count]) |*row, ref| {
            const status = self.directory_status.find(ref.url);
            row.* = .{ .name = ref.name, .url = ref.url, .sub = ref.sub, .live_label = if (status) |s| s.label() else "", .live_online = if (status) |s| s.online else false };
        }
        return rows;
    }
    pub fn featured_live_label(self: *const Model) []const u8 {
        const status = self.directory_status.find(api.default_base) orelse return "";
        return status.label();
    }
    pub fn featured_live_online(self: *const Model) bool {
        const status = self.directory_status.find(api.default_base) orelse return false;
        return status.online;
    }
    pub fn has_discover(self: *const Model) bool {
        return self.discover_count > 0;
    }
    pub fn base_display(self: *const Model) []const u8 {
        var s = self.base;
        if (std.mem.startsWith(u8, s, "https://")) s = s["https://".len..];
        if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..];
        return s;
    }

    // The featured station (onboarding's known-station row).
    pub fn featured_url(self: *const Model) []const u8 {
        _ = self;
        return api.default_base;
    }
    pub fn featured_name(self: *const Model) []const u8 {
        _ = self;
        return "SUB/WAVE";
    }
    pub fn featured_display(self: *const Model) []const u8 {
        _ = self;
        var s: []const u8 = api.default_base;
        if (std.mem.startsWith(u8, s, "https://")) s = s["https://".len..];
        return s;
    }

    // ------------------------------------------------------------ onboarding
    pub fn ob_entry(self: *const Model) bool {
        return !self.ob_checking;
    }
    pub fn ob_scheme(self: *const Model) []const u8 {
        return if (self.ob_https) "https://" else "http://";
    }
    pub fn has_ob_diag(self: *const Model) bool {
        return self.ob_diag.len > 0;
    }
    pub fn has_ob_raw(self: *const Model) bool {
        return self.ob_raw.len > 0;
    }
    pub const SchemeRow = struct {
        label: []const u8 = "",
        https: bool = true,
        on: bool = false,
    };
    pub fn scheme_rows(self: *const Model, arena: std.mem.Allocator) []const SchemeRow {
        const out = arena.alloc(SchemeRow, 2) catch return &.{};
        out[0] = .{ .label = "HTTPS", .https = true, .on = self.ob_https };
        out[1] = .{ .label = "HTTP", .https = false, .on = !self.ob_https };
        return out;
    }

    pub const ObStepRow = struct {
        label: []const u8,
        stat: []const u8,
        done: bool,
        running: bool,
        failed: bool,
    };
    pub fn ob_step_rows(self: *const Model, arena: std.mem.Allocator) []const ObStepRow {
        const labels = [4][]const u8{ "Resolving host", "Controller · /health", "Icecast · /stream", "DJ booth · LLM link" };
        const out = arena.alloc(ObStepRow, 4) catch return &.{};
        for (out, labels, self.ob_steps) |*row, label, s| {
            row.* = .{
                .label = label,
                .stat = switch (s) {
                    .ok => "ok",
                    .run => "…",
                    .fail => "failed",
                    .wait => "",
                },
                .done = s == .ok,
                .running = s == .run,
                .failed = s == .fail,
            };
        }
        return out;
    }

    // --------------------------------------------------------------- themes
    pub const ThemeRow = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        desc: []const u8 = "",
        has_desc: bool = false,
        on: bool = false,
    };
    pub fn theme_rows(self: *const Model, arena: std.mem.Allocator) []const ThemeRow {
        const out = arena.alloc(ThemeRow, self.theme_count) catch return &.{};
        for (out, 0..) |*row, i| {
            const name = if (self.theme_names[i].len > 0) self.theme_names[i] else self.theme_ids[i];
            row.* = .{
                .id = self.theme_ids[i],
                .name = name,
                .desc = self.theme_descs[i],
                .has_desc = self.theme_descs[i].len > 0,
                .on = self.theme_override.len > 0 and std.mem.eql(u8, self.theme_ids[i], self.theme_override),
            };
        }
        return out;
    }
    pub fn follow_on(self: *const Model) bool {
        return self.theme_override.len == 0;
    }
    pub fn theme_value(self: *const Model) []const u8 {
        if (self.theme_override.len == 0) return "Station default";
        for (0..self.theme_count) |i| {
            if (std.mem.eql(u8, self.theme_ids[i], self.theme_override))
                return if (self.theme_names[i].len > 0) self.theme_names[i] else self.theme_ids[i];
        }
        return self.theme_override;
    }

    // --------------------------------------------------------- stream format
    /// Does the station advertise the mount as live? MP3 is the always-on
    /// floor; the rest need their explicit flag (unknown-yet counts as NOT
    /// advertised — the picker only offers what's confirmed).
    pub fn stationEnables(self: *const Model, format: StreamFormat) bool {
        return switch (format) {
            .mp3 => true,
            .aac => self.stream_aac,
            .opus => self.stream_opus,
            .flac => self.stream_flac,
        };
    }
    /// The format to actually tune with: the stored pick while the platform
    /// can decode it and the station still (or plausibly, pre-first-poll)
    /// serves it; everything else falls back to the universal MP3 floor.
    pub fn effectiveFormat(self: *const Model) StreamFormat {
        if (!stream_format.platformSupports(self.format_pref)) return .mp3;
        if (self.stream_flags_known and !self.stationEnables(self.format_pref)) return .mp3;
        return self.format_pref;
    }
    pub const FormatRow = struct {
        id: []const u8 = "",
        label: []const u8 = "",
        detail: []const u8 = "",
        on: bool = false,
        available: bool = false,
    };
    /// Every format THIS platform can decode, whether or not the station
    /// serves it — an unavailable row states why in its detail line instead of
    /// vanishing, so a station down to the MP3 floor reads as a fact rather
    /// than a missing feature. Formats the platform cannot decode stay out
    /// entirely: there is nothing a listener on macOS can do about FLAC, so
    /// listing it would only be noise. Always contains at least MP3.
    pub fn format_rows(self: *const Model, arena: std.mem.Allocator) []const FormatRow {
        var out: std.ArrayList(FormatRow) = .empty;
        const effective = self.effectiveFormat();
        for (StreamFormat.all) |f| {
            if (!stream_format.platformSupports(f)) continue;
            const available = self.stationEnables(f);
            out.append(arena, .{
                .id = f.id(),
                .label = f.label(),
                .detail = if (available) f.detail() else "not served by this station",
                .on = available and f == effective,
                .available = available,
            }) catch break;
        }
        return out.items;
    }
    /// The back panel's SIGNAL row and the transport deck's chip, e.g.
    /// "MP3 192k". The bitrate rides along only while the station's primary
    /// mount IS the format being played — see stream_primary.
    pub fn format_value(self: *const Model, arena: std.mem.Allocator) []const u8 {
        const effective = self.effectiveFormat();
        const label = effective.label();
        const primary = self.stream_primary orelse return label;
        if (primary != effective or self.stream_bitrate == 0) return label;
        return std.fmt.allocPrint(arena, "{s} {d}k", .{ label, self.stream_bitrate }) catch label;
    }

    // The chart-bound spectrum series.
    pub fn bands(self: *const Model) []const f32 {
        return self.band_levels[0..];
    }

    // One-word transport status (tray + status assertions).
    // ----------------------------------------------------------------- like
    pub fn like_count_str(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.like_count == 0) return "";
        return std.fmt.allocPrint(arena, "{d}", .{self.like_count}) catch "";
    }
    pub fn like_hint(self: *const Model) []const u8 {
        return if (self.like_liked) "Liked" else "Like this track";
    }

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
    // of the dead-state lint.
    pub const view_unbound = .{
        "timezone_store", "station_locale", "station_offset_minutes", "station_clock", "station_second_timer_active",
        "stationDay", "nowShow", "day_picked", "slot_topic_open", "slot_host_open",
        "now_topic_open", "now_host_open", "host_id_store", "host_id",
        "now_guests_store", "now_guests", "persona_roster", "persona_images",
        "persona_loading", "next_persona_id", "persona_url_store", "persona_cache_store",
        "show_ids_store", "show_guests_store",
        "ctx_festival_store", "ctx_festival", "poll_cadence", "directory_status",
        "req_return_allowed", "req_return_armed",
        "main_occluded",
        // fixed backing buffers behind the bound slice fields
        "title_buf",          "artist_buf",          "album_buf",           "genre_buf",
        "dj_buf",             "show_buf",            "host_buf",            "cover_sid_buf",
        "cover_url_buf",      "theme_id_buf",        "req_id_buf",          "booth_buf",
        "station_name_buf",   "station_loc_buf",     "key_buf",             "moods_buf",
        "energy_buf",         "ctx_show_buf",        "ctx_vibe_buf",        "ctx_cond_buf",
        "req_ack_buf",        "req_track_title_buf", "req_track_artist_buf",
        "ob_target_url_buf",  "ob_target_name_buf",  "ob_diag_buf",
        // update notice is bound through has_update/update_label; opener state
        // only serializes browser launches in update/fx.
        "update_tag_buf",     "update_tag",          "opener_inflight",
        // internal / derived-source state
        "phase",              "transport",           "volume",              "muted",
        "volume_widget_seen",
        "buffering",          "elapsed_ms",          "band_levels",         "req_buffer",
        "req_name_buffer",    "retry",               "offline_streak",      "stream_failed",
        "stream_online",      "cover_sid",           "next_cover_id",       "req_id",
        "cover_loading_id",   "cover_cache_buf",     "cache_dir",           "cache_dir_buf",
        "theme_scheme",       "station_colors",      "active_tab",          "sheet",
        "booth_filter",       "day_sel",             "req_phase",           "mini_open",
        "sleep_deadline_ms",  "sleep_minutes",       "now_wall_ms",         "latency_ms",
        "probe_t0",           "probe_fails",         "probe_inflight",      "probe_slow",
        "sched_grid",         "dj",                  "ob_https",            "ob_checking",
        "ob_scheme",          "sidebar_open",        "booth_line",          "has_tokens",
        "meta_line",          "has_meta",            "mood_line",           "has_mood",
        "state_line",         "has_state",           "has_booth",           "panel_open",
        "ob_steps",           "ob_done",             "chrome_top",
        // heartbeat bookkeeping consumed only by the .tick_feed arm, never
        // by markup (see src/diag.zig and issue #23)
        "hb_tick_count",      "hb_audio_events",
        // stream-format state (bound via format_rows/format_value)
        "format_pref",        "stream_flags_known",  "stream_opus",
        "stream_flac",        "stream_aac",          "stationEnables",      "effectiveFormat",
        "stream_primary",     "stream_bitrate",
        // private-station gate internals (bound via pw_text/auth_checking/…)
        "privacy_private",    "privacy_listener_auth", "auth_gate",         "station_pw",
        "station_pw_buf",     "pw_buffer",           "auth_try",            "auth_try_buf",
        "auth_from_store",    "auth_body_buf",       "station_locked",
        "station_memory", "use_secure_credentials", "keep_station_memory", "credentials_ready", "credentials_blocked",
        "credentials_saving", "credentials_dirty", "auth_recheck", "auth_recheck_inflight", "auth_recheck_body_buf",
        "ob_raw_buf", "ob_allow_fallback", "ob_tried_https", "ob_from_sidebar",
        // station / settings / theme-override state
        "base",               "base_buf",            "stream_url_buf",      "settings_path",
        "settings_path_buf",  "settings_json_buf",   "station_buffer",      "theme_override",
        "self_exe_path",      "self_exe_path_buf",
        "theme_override_buf", "theme_ids",           "theme_ids_store",     "theme_names",
        "theme_names_store",  "theme_descs",         "theme_descs_store",   "tray_status",
        "tray_status_buf",    "tray_track",          "tray_track_buf",
        "theme_count",        "save_inflight",       "save_dirty",
        "recents_name_store", "recents_url_store",   "recents",             "recents_count",
        "discover_name_store", "discover_url_store", "discover_sub_store",  "discover_rows",
        "discover_count",
        // like state consumed by the Zig stage view / update, not markup
        "like_song_buf",      "like_song",           "like_body_buf",       "like_pending",
        "like_count",         "like_count_str",      "like_hint",
        // consumed by derived methods, not bound directly
        "elapsed_str",        "vol_pct",             "listeners",           "genre",
        "album",              "theme_id",            "req_ack",
        "moods",              "energy",              "musical_key",         "track_bpm",
        "track_year",         "track_duration_s",    "ctx_show",            "ctx_vibe",
        "ctx_cond",           "ctx_temp",            "show",                "host",
        "llm_tokens",         "status_word",         "play_label",
        "play_icon",          "tune_label",          "mute_label",          "vol_display",
        // schedule / guide / feed backing storage
        "show_names_store",   "show_topics_store",   "show_personas_store", "show_rows",
        "show_count",         "up_title_store",      "up_artist_store",     "up_req_store",
        "upcoming_rows",      "upcoming_count",      "hist_title_store",    "hist_artist_store",
        "hist_time_store",    "history_rows",        "history_count",       "booth_time_store",
        "booth_text_store",   "booth_turns",         "booth_count",
        // track-change notifications (notify_track is bound by the back
        // panel's switch; the rest is update-only state)
        "app_active",         "shouldNotifyTrack",   "trackNotification",
        // discord rich presence (bound via getters, not the raw fields)
        "discord_connected",  "discord_retry_count",
        "discord_spawn_key",  "discord_last_payload", "discord_last_payload_buf",
        "discord_id_buffer",  "discord_client_id_buf", "discord_error",
        "effectiveDiscordClientId",
        // per-track elapsed plumbing (surfaced via elapsed_str/np_head)
        "track_started_at_s", "track_anchor_ms",     "track_elapsed_ms",
        "listener", "listener_np_key", "listener_state_key", "listener_session_key",
        "listener_like_key", "listener_fetches", "listener_generation",
        "listener_like_generation", "listener_feed_deferred", "listener_like_deferred",
        "raw_booth", "raw_booth_count", "booth_persona_store", "dj_talking",
    };
};

pub const App = native_sdk.UiApp(Model, Msg);
pub const Effects = App.Effects;

pub const Msg = union(enum) {
    // effect results
    tick_feed: native_sdk.EffectTimer,
    tick_background_feed: native_sdk.EffectTimer,
    tick_directory_status: native_sdk.EffectTimer,
    got_directory_status: native_sdk.EffectResponse,
    tick_request_return: native_sdk.EffectTimer,
    tick_reconnect: native_sdk.EffectTimer,
    tick_theme: native_sdk.EffectTimer,
    tick_signal: native_sdk.EffectTimer,
    tick_second: native_sdk.EffectTimer,
    tick_listener: native_sdk.EffectTimer,
    tick_ob_step: native_sdk.EffectTimer,
    got_np: native_sdk.EffectResponse,
    got_state: native_sdk.EffectResponse,
    got_themes: native_sdk.EffectResponse,
    got_cover: native_sdk.EffectImageResult,
    got_persona: native_sdk.EffectImageResult,
    got_session: native_sdk.EffectResponse,
    got_schedule: native_sdk.EffectResponse,
    got_health: native_sdk.EffectResponse,
    got_dj: native_sdk.EffectResponse,
    got_directory: native_sdk.EffectResponse,
    got_beacon: native_sdk.EffectResponse,
    got_like_status: native_sdk.EffectResponse,
    got_like_post: native_sdk.EffectResponse,
    got_reqpost: native_sdk.EffectResponse,
    got_reqstat: native_sdk.EffectResponse,
    got_ob_health: native_sdk.EffectResponse,
    got_ob_dj: native_sdk.EffectResponse,
    tick_reqpoll: native_sdk.EffectTimer,
    tick_save: native_sdk.EffectTimer,
    saved: native_sdk.EffectFileResult,
    discord_line: native_sdk.EffectLine,
    discord_exited: native_sdk.EffectExit,
    tick_discord_retry: native_sdk.EffectTimer,
    audio_event: native_sdk.EffectAudio,
    chrome_changed: ChromeInsets,
    got_update: native_sdk.EffectResponse,
    tick_update: native_sdk.EffectTimer,
    opener_exited: native_sdk.EffectExit,

    // transport + audio
    toggle_play,
    tune_toggle, // power button: stopped <-> playing
    tune_out,
    vol_up,
    vol_down,
    volume_changed, // slider moved; value mirrored by Options.sync
    toggle_mute,

    // navigation
    pick_tab: Tab,
    open_timeline,
    open_booth,
    close_panel,
    toggle_sidebar,
    escape,
    open_panel,
    open_sleep,
    open_themes,
    open_format,
    open_discord,
    open_release, // update notice row -> release page in the browser
    open_support, // back panel -> the ko-fi tip page in the browser
    close_sheet,
    toggle_mini,
    expand_mini,
    mini_closed,

    // Right-click on the sleeve. The SDK has no OS now-playing surface, so
    // "what is this track" leaves the app through the clipboard or not at all.
    copy_track,
    copy_station,

    // sleep timer
    sleep_pick: i64,
    sleep_cycle, // tray: off -> 15 -> 30 -> 45 -> 60 -> 90 -> off
    cancel_sleep,

    // booth / schedule
    set_booth_filter: BoothFilter,
    pick_day: i64,
    toggle_slot_topic: i64,
    toggle_slot_host: i64,
    toggle_now_topic,
    toggle_now_host,

    // request slip
    req_edit: canvas.TextInputEvent,
    req_name_edit: canvas.TextInputEvent,
    chip_pick: []const u8,
    submit_req,
    reset_request,

    // private-station gate
    pw_edit: canvas.TextInputEvent,
    submit_pw,
    got_station_auth: native_sdk.EffectResponse,
    got_station_credentials: native_sdk.EffectCredentialsResult,
    tick_auth_recheck: native_sdk.EffectTimer,
    got_auth_recheck: native_sdk.EffectResponse,

    // stations
    station_edit: canvas.TextInputEvent,
    tune_station, // from the sidebar address field
    pick_recent: []const u8, // payload = url
    pick_discover: []const u8, // payload = url
    forget_recent: []const u8, // payload = url
    follow_station,
    pick_theme: []const u8, // payload = theme id
    pick_format: []const u8, // payload = format id ("mp3" | "aac" | "opus" | "flac")
    toggle_notify,
    toggle_discord,
    discord_id_edit: canvas.TextInputEvent,
    submit_discord_id,
    clear_discord_id,

    // listener like (stage heart / mini heart / L key)
    press_like,

    // tray-only window/app verbs (SDK 0.6.0: fx.showWindow / fx.quitApp — the
    // model can drive these itself now, so no reserved host-side tray ids).
    show_player,
    quit_app,

    // app-level lifecycle (SDK 0.6.0 on_lifecycle), not window focus
    app_activated,
    app_deactivated,
    main_occlusion: bool,

    // onboarding
    ob_pick_scheme: bool,
    ob_run_check,
    ob_pick_known: []const u8, // payload = url (known/discover rows)
    ob_back,
    ob_tune_in,
    ob_continue_http,

    // Effect-result Msgs dispatched by the runtime/fx, not markup.
    pub const view_unbound = .{
        "got_persona",
        "tick_background_feed", "tick_directory_status", "got_directory_status", "tick_request_return",
        "main_occlusion",
        "tick_feed",     "tick_reconnect", "tick_theme",  "tick_reqpoll",
        "tick_signal",   "tick_second",    "tick_ob_step", "got_np",
        "got_state",     "got_themes",     "got_cover",   "got_session",
        "got_reqpost",   "got_reqstat",    "got_health",  "got_dj",
        "got_directory", "got_beacon",     "got_ob_health", "got_ob_dj",
        "got_like_status", "got_like_post",
        "audio_event",   "saved",          "got_schedule", "tick_save",
        "chrome_changed", "toggle_play",   "vol_up",      "vol_down",
        "escape",        "mini_closed",    "tune_out",    "toggle_mini",
        "sleep_cycle",   "open_timeline",  "open_booth",
        "discord_line",  "discord_exited", "tick_discord_retry",
        "show_player",   "quit_app",       "app_activated", "app_deactivated",
        "got_update",    "tick_update",    "opener_exited",
        "tick_listener",
        "got_station_auth",
        "got_station_credentials", "tick_auth_recheck", "got_auth_recheck",
    };
};

// ---------------------------------------------------------------- helpers
fn setStr(buf: []u8, out: *[]const u8, v: []const u8) void {
    out.* = utf8.copyInto(buf, v);
}

// First letters of the first two words, uppercased ("Juno Reyes" -> "JR").
fn wordInitials(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const out = arena.alloc(u8, 2) catch return "";
    var n: usize = 0;
    var at_word = true;
    for (s) |ch| {
        if (ch == ' ') {
            at_word = true;
        } else if (at_word and std.ascii.isAlphabetic(ch)) {
            out[n] = std.ascii.toUpper(ch);
            n += 1;
            if (n >= 2) break;
            at_word = false;
        } else {
            at_word = false;
        }
    }
    return out[0..n];
}

fn asciiUpper(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    const out = arena.alloc(u8, s.len) catch return s;
    for (out, s) |*o, ch| o.* = std.ascii.toUpper(ch);
    return out;
}

// Append " · "-joined non-empty parts (masthead/meta line composition).
fn appendPart(out: *std.ArrayList(u8), arena: std.mem.Allocator, part: []const u8) void {
    if (part.len == 0) return;
    if (out.items.len > 0) out.appendSlice(arena, " · ") catch return;
    out.appendSlice(arena, part) catch return;
}

fn fmtSecs(arena: std.mem.Allocator, total_secs: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, total_secs));
    const hours = secs / 3600;
    const mins = (secs / 60) % 60;
    const s = secs % 60;
    if (hours > 0)
        return std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, s }) catch "0:00";
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ mins, s }) catch "0:00";
}

// "2026-07-17T02:47:33Z" → "02:47" (best-effort; "" when not ISO-shaped).
fn isoToHhmm(iso: []const u8) []const u8 {
    if (iso.len >= 16 and iso[10] == 'T') return iso[11..16];
    return "";
}

// Shared with booth boundaries: the caller supplies the airing epoch, while
// the model owns the station's current offset and display locale.
pub fn formatStationStamp(arena: std.mem.Allocator, at_s: ?i64, offset_minutes: i64, display_locale: station_time.Locale, seconds: bool) []const u8 {
    const at = at_s orelse return "";
    var buf: [32]u8 = undefined;
    return arena.dupe(u8, station_time.clock(&buf, at *| 1000, offset_minutes, display_locale, seconds)) catch "";
}

fn startStream(model: *Model, fx: *Effects) void {
    // A manual (re)start supersedes any scheduled reconnect — otherwise a
    // pending backoff timer would fire later and restart the fresh stream
    // mid-listen a second time.
    fx.cancelTimer(keys.reconnect);
    // Stream URL lives in a stable model buffer (the audio effect streams from
    // it continuously; a stack buffer could dangle). A stored station password
    // rides along as ?auth= whenever present — Icecast ignores the query when
    // listener auth is off (mirrors the web's withStreamAuth).
    var mount_buf: [320]u8 = undefined;
    const url = if (model.station_pw.len == 0)
        api.streamMount(&model.stream_url_buf, model.base, model.effectiveFormat().mount()) catch return
    else blk: {
        const bare = api.streamMount(&mount_buf, model.base, model.effectiveFormat().mount()) catch return;
        break :blk api.withStreamAuth(&model.stream_url_buf, bare, model.station_pw) catch return;
    };
    fx.playAudio(.{
        .key = keys.audio,
        .path = "",
        .url = url,
        .cache_path = "", // stream-only: endless Icecast, no disk cache
        .expected_bytes = 0,
        .on_event = Effects.audioMsg(.audio_event),
    });
    fx.setAudioVolume(if (model.muted) 0.0 else model.volume);
    diag.print("stream start format={s}", .{model.effectiveFormat().id()});
    model.transport = .playing;
    model.buffering = true;
    armAuthRecheck(model, fx);
    updateDiscordPresence(model, fx);
}

fn fetchFeed(model: *Model, fx: *Effects) void {
    fetchTrack(model, fx);
    fetchSession(model, fx);
}

// Now-playing and state always travel as one joined pair: the listener hold
// resolves the audible start from both legs, so neither is polled alone.
fn fetchTrack(model: *Model, fx: *Effects) void {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    if (!model.listener.waiting_np and !model.listener.waiting_state and
        (!model.listener_fetches.available(model.listener_np_key) or !model.listener_fetches.available(model.listener_state_key)))
        model.listener_feed_deferred = true;
    if (model.listener_fetches.available(model.listener_np_key) and model.listener_fetches.available(model.listener_state_key) and model.listener.beginPoll()) {
        model.listener_feed_deferred = false;
        _ = model.listener_fetches.start(model.listener_np_key, model.listener_generation);
        _ = model.listener_fetches.start(model.listener_state_key, model.listener_generation);
        if (api.nowPlaying(&b1, model.base)) |u| fx.fetch(.{ .key = model.listener_np_key, .url = u, .on_response = Effects.responseMsg(.got_np) }) else |_| {
            _ = model.listener_fetches.finish(model.listener_np_key, model.listener_generation);
            model.listener.failTrack();
        }
        if (api.state(&b2, model.base)) |u| fx.fetch(.{ .key = model.listener_state_key, .url = u, .on_response = Effects.responseMsg(.got_state) }) else |_| {
            _ = model.listener_fetches.finish(model.listener_state_key, model.listener_generation);
            model.listener.receiveCurrent(null);
        }
    }
}

fn fetchSession(model: *Model, fx: *Effects) void {
    var b3: [256]u8 = undefined;
    if (model.listener_fetches.start(model.listener_session_key, model.listener_generation)) {
        if (api.session(&b3, model.base)) |u| fx.fetch(.{ .key = model.listener_session_key, .url = u, .on_response = Effects.responseMsg(.got_session) }) else |_| {
            _ = model.listener_fetches.finish(model.listener_session_key, model.listener_generation);
        }
    }
}

fn pollCadence(model: *const Model) polling.Cadence {
    return polling.cadence(model.phase == .player, feedActive(model), model.transport != .stopped, model.transport == .playing, model.probe_slow);
}

fn feedActive(model: *const Model) bool {
    // Mini mode explicitly minimizes main, including on GTK where the host
    // cannot report occlusion. Its small view needs the track, not the feeds.
    return model.app_active and !model.main_occluded and !model.mini_open;
}

fn syncPolling(model: *Model, fx: *Effects) void {
    const next = pollCadence(model);
    if (std.meta.eql(next, model.poll_cadence)) return;
    const old = model.poll_cadence;
    model.poll_cadence = next;
    if (old.now_playing_ms != next.now_playing_ms) {
        fx.cancelTimer(keys.feed_timer);
        if (next.now_playing_ms > 0)
            fx.startTimer(.{ .key = keys.feed_timer, .interval_ms = next.now_playing_ms, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_feed) })
        else {
            fx.cancel(model.listener_np_key);
            fx.cancel(model.listener_state_key);
        }
    }
    if (old.session_ms != next.session_ms) {
        fx.cancelTimer(keys.background_feed_timer);
        if (next.session_ms > 0 and next.session_ms != next.now_playing_ms)
            fx.startTimer(.{ .key = keys.background_feed_timer, .interval_ms = next.session_ms, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_background_feed) });
        if (next.session_ms == 0) fx.cancel(model.listener_session_key);
    }
    if (old.themes_ms != next.themes_ms) {
        fx.cancelTimer(keys.theme_timer);
        if (next.themes_ms > 0)
            fx.startTimer(.{ .key = keys.theme_timer, .interval_ms = next.themes_ms, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_theme) })
        else
            fx.cancel(keys.fetch_themes);
    }
    if (old.signal_ms != next.signal_ms) {
        fx.cancelTimer(keys.signal_timer);
        if (next.signal_ms > 0)
            fx.startTimer(.{ .key = keys.signal_timer, .interval_ms = next.signal_ms, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_signal) })
        else {
            fx.cancel(keys.fetch_health);
            model.probe_inflight = false;
        }
    }
}

fn directoryVisible(model: *const Model) bool {
    if (!model.app_active or model.main_occluded or model.mini_open) return false;
    return if (model.phase == .onboarding) !model.ob_checking else model.sidebar_open and !model.station_locked();
}

fn pumpDirectoryStatus(model: *Model, fx: *Effects) void {
    while (model.directory_status.next()) |i| {
        var b: [320]u8 = undefined;
        if (api.nowPlaying(&b, model.directory_status.entries[i].url())) |u| {
            fx.fetch(.{ .key = keys.directory_status_base + i, .url = u, .timeout_ms = 8000, .on_response = Effects.responseMsg(.got_directory_status) });
        } else |_| {
            model.directory_status.entries[i].pending = false;
            model.directory_status.entries[i].setStatus(false, "", "");
        }
    }
}

fn syncDirectoryStatus(model: *Model, fx: *Effects, force: bool) void {
    const visible = directoryVisible(model);
    if (!force and visible == model.directory_status.enabled) return;
    model.directory_status.enabled = visible;
    model.directory_status.begin();
    if (visible) {
        if (model.phase == .onboarding) model.directory_status.want(api.default_base);
        for (model.recents[0..model.recents_count]) |st| model.directory_status.want(st.url);
        for (model.discover_rows[0..model.discover_count]) |st| model.directory_status.want(st.url);
    }
    for (&model.directory_status.entries, 0..) |*entry, i| {
        if (!entry.wanted and entry.pending) fx.cancel(keys.directory_status_base + i);
    }
    fx.cancelTimer(keys.directory_status_timer);
    if (visible) {
        fx.startTimer(.{ .key = keys.directory_status_timer, .interval_ms = station_status.interval_ms, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_directory_status) });
        pumpDirectoryStatus(model, fx);
    }
}

fn cancelRequestReturn(model: *Model, fx: *Effects) void {
    model.req_return_allowed = false;
    model.req_return_armed = false;
    fx.cancelTimer(keys.request_return);
}

fn scheduleRequestReturn(model: *Model, fx: *Effects) void {
    if (!model.req_return_allowed or model.active_tab != .request or model.req_return_armed) return;
    model.req_return_armed = true;
    fx.startTimer(.{ .key = keys.request_return, .interval_ms = 2800, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_request_return) });
}

// Minimal JSON string escape (quotes/backslashes/newlines; drops other
// control bytes).
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
    if (!feedActive(model)) return;
    var b: [256]u8 = undefined;
    if (api.themes(&b, model.base)) |u| fx.fetch(.{ .key = keys.fetch_themes, .url = u, .on_response = Effects.responseMsg(.got_themes) }) else |_| {}
}

// Daily GitHub release poll. GitHub's API rejects UA-less requests and the
// SDK sets no default User-Agent, so both headers are explicit. Every failure
// mode (offline, rate-limited, truncated, junk) is silent — the next tick
// retries.
fn checkForUpdate(fx: *Effects) void {
    fx.fetch(.{
        .key = keys.fetch_update,
        .url = updater.release_api_url,
        .headers = &.{
            .{ .name = "User-Agent", .value = "SUBWAVE-Player" },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        },
        .timeout_ms = 10_000,
        .on_response = Effects.responseMsg(.got_update),
    });
}

// Hand a comptime-baked URL to the desktop's browser. `opener_inflight` is one
// guard across every link, not one per link: a double-press (or a press on a
// second link while the first opener is still up) must not stack processes,
// and the opener exits the moment the browser has the URL.
fn openLink(model: *Model, fx: *Effects, key: u64, argv: []const []const u8) void {
    if (model.opener_inflight) return;
    model.opener_inflight = true;
    fx.spawn(.{ .key = key, .argv = argv, .on_exit = Effects.exitMsg(.opener_exited) });
}

fn fetchSchedule(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.schedule(&b, model.base)) |u| fx.fetch(.{ .key = keys.fetch_schedule, .url = u, .on_response = Effects.responseMsg(.got_schedule) }) else |_| {}
}

fn fetchDj(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.dj(&b, model.base)) |u| fx.fetch(.{ .key = keys.fetch_dj, .url = u, .on_response = Effects.responseMsg(.got_dj) }) else |_| {}
}

fn fetchDirectory(fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.directory(&b)) |u| fx.fetch(.{ .key = keys.fetch_directory, .url = u, .on_response = Effects.responseMsg(.got_directory) }) else |_| {}
}

// Fire-and-forget audience beacon (mirrors the mobile app's utmSource report).
fn postBeacon(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.beacon(&b, model.base)) |u| {
        fx.fetch(.{
            .key = keys.post_beacon,
            .method = .POST,
            .url = u,
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .body = "{\"utmSource\":\"desktop\"}",
            .on_response = Effects.responseMsg(.got_beacon),
        });
    } else |_| {}
}

// Apply a settings.json blob (called at startup from settings.loadFromDisk).
pub fn applySettingsJson(model: *Model, bytes: []const u8) void {
    const parsed = json.parse(json.Settings, std.heap.page_allocator, bytes) catch return;
    defer parsed.deinit();
    const s = parsed.value;
    var legacy_station_valid = true;
    if (s.volume) |v| model.volume = std.math.clamp(v, 0.0, 1.0);
    if (s.themeOverride) |t| setStr(&model.theme_override_buf, &model.theme_override, t);
    // Unknown ids (or none) keep the MP3 floor.
    if (s.streamFormat) |f| {
        if (stream_format.fromId(f)) |fmt| model.format_pref = fmt;
    }
    if (s.station) |st| {
        if (st.len > 0) {
            if (api.normalizeBase(&model.base_buf, st)) |b| {
                model.base = b;
                // A saved station means onboarding already happened. Not
                // logged here: this runs via settings.loadFromDisk, which
                // main.zig calls before diag.open(), so a diag.print call at
                // this call site can never actually appear in the log.
                // main.zig logs the same fact once the station is resolved.
                model.phase = .player;
            } else |_| {
                legacy_station_valid = false;
            }
        }
    }
    if (s.stationName) |n| {
        if (n.len > 0) setStr(&model.station_name_buf, &model.station_name, n);
    }
    // Re-validated against /station-auth the first time a state poll reports
    // a privacy lock — a rotated password clears itself then.
    if (s.stationPassword) |p| {
        if (legacy_station_valid and p.len > 0 and p.len <= model.station_pw_buf.len)
            setStr(&model.station_pw_buf, &model.station_pw, p);
    }
    if (s.recents) |list| {
        model.recents_count = 0;
        for (list) |r| {
            if (model.recents_count >= max_recents) break;
            const raw = r.url orelse continue;
            var url_buf: [256]u8 = undefined;
            const url = api.normalizeBase(&url_buf, raw) catch continue;
            var duplicate = false;
            for (model.recents[0..model.recents_count]) |recent| duplicate = duplicate or std.mem.eql(u8, recent.url, url);
            if (duplicate) continue;
            const i = model.recents_count;
            setStr(&model.recents_url_store[i], &model.recents[i].url, url);
            setStr(&model.recents_name_store[i], &model.recents[i].name, r.name orelse url);
            model.recents_count += 1;
        }
    }
    _ = model.station_memory.put(model.base, model.format_pref, model.station_pw) catch false;
    for (model.recents[0..model.recents_count]) |recent| {
        if (model.station_memory.get(recent.url) == null)
            _ = model.station_memory.put(recent.url, .mp3, "") catch false;
    }
    if (s.stationSettings) |map| {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            var b: [256]u8 = undefined;
            const base = api.normalizeBase(&b, entry.key_ptr.*) catch continue;
            // Imported entries have to belong to a retained station.
            const old = model.station_memory.get(base) orelse continue;
            const value = entry.value_ptr.*;
            const fmt = if (value.streamFormat) |f| stream_format.fromId(f) orelse old.format else old.format;
            const pw = value.stationPassword orelse old.password();
            _ = model.station_memory.put(base, fmt, pw) catch false;
        }
    }
    restoreStationSettings(model);
    if (s.notifyTrack) |v| model.notify_track = v;
    if (s.discordEnabled) |v| model.discord_enabled = v;
    if (s.discordClientId) |id| {
        // Same gate as the sheet's input — a hand-edited invalid ID is
        // dropped rather than left to fail the handshake forever.
        if (discord_rpc.isValidClientId(id)) setStr(&model.discord_client_id_buf, &model.discord_client_id, id);
    }
}

// Persist the current settings (async via fx.writeFile). While a write is in
// flight further saves set save_dirty; the .saved result re-saves once, so the
// last state always lands on disk.
fn rememberStationSettings(model: *Model) void {
    if (!model.keep_station_memory) return;
    model.credentials_dirty = (model.station_memory.put(model.base, model.format_pref, model.station_pw) catch false) or model.credentials_dirty;
}

pub fn restoreStationSettings(model: *Model) void {
    model.format_pref = .mp3;
    model.station_pw = "";
    model.keep_station_memory = true;
    if (model.station_memory.get(model.base)) |entry| {
        model.format_pref = entry.format;
        setStr(&model.station_pw_buf, &model.station_pw, entry.password());
    }
}

fn pruneStationSettings(model: *Model) void {
    var urls: [max_recents][]const u8 = undefined;
    for (model.recents[0..model.recents_count], 0..) |recent, i| urls[i] = recent.url;
    model.credentials_dirty = model.station_memory.retain(model.base, urls[0..model.recents_count]) or model.credentials_dirty;
}

fn settingsSnapshot(model: *Model) ![]const u8 {
    var w = std.Io.Writer.fixed(&model.settings_json_buf);
    try w.print("{{\"volume\":{d:.2},\"themeOverride\":", .{model.volume});
    try std.json.Stringify.value(model.theme_override, .{}, &w);
    try w.writeAll(",\"station\":");
    try std.json.Stringify.value(model.base, .{}, &w);
    try w.writeAll(",\"stationName\":");
    try std.json.Stringify.value(model.station_name, .{}, &w);
    try w.print(",\"discordEnabled\":{s},\"discordClientId\":\"{s}\",\"notifyTrack\":{s},\"recents\":[", .{
        if (model.discord_enabled) "true" else "false",
        model.discord_client_id,
        if (model.notify_track) "true" else "false",
    });
    for (model.recents[0..model.recents_count], 0..) |recent, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(recent.name, .{}, &w);
        try w.writeAll(",\"url\":");
        try std.json.Stringify.value(recent.url, .{}, &w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"stationSettings\":{");
    for (model.station_memory.entries[0..model.station_memory.count], 0..) |*entry, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(entry.base(), .{}, &w);
        try w.print(":{{\"streamFormat\":\"{s}\"", .{entry.format.id()});
        if (passwordsInSettingsFile(model) and entry.password_len > 0) {
            try w.writeAll(",\"stationPassword\":");
            try std.json.Stringify.value(entry.password(), .{}, &w);
        }
        try w.writeByte('}');
    }
    try w.writeAll("}}");
    return w.buffered();
}

// Linux has no working vault, and after a vault failure the settings file
// stays the password store for the session: a legacy secret is never scrubbed
// and a newly validated one still survives a restart.
fn passwordsInSettingsFile(model: *const Model) bool {
    return !model.use_secure_credentials or model.credentials_blocked;
}

fn saveSettings(model: *Model, fx: *Effects) void {
    pruneStationSettings(model);
    rememberStationSettings(model);
    if (!model.use_secure_credentials) model.credentials_dirty = false;
    // Wait for the vault read (so an imported secret isn't scrubbed before its
    // replacement is known) and for an in-flight vault write to confirm.
    if (!model.credentials_ready or model.credentials_saving) {
        model.save_dirty = true;
        return;
    }
    // A vault we could not read or write is never overwritten.
    if (model.credentials_dirty and !model.credentials_blocked) {
        var vault_buf: [station_access.vault_bytes]u8 = undefined;
        const secret = model.station_memory.vaultSnapshot(&vault_buf) catch return;
        model.credentials_dirty = false;
        model.credentials_saving = true;
        fx.credentialsSet(.{ .key = keys.station_credentials, .credential_key = station_access.vault_key, .secret = secret, .on_result = Effects.credentialsMsg(.got_station_credentials) });
        @memset(&vault_buf, 0);
        return;
    }
    if (model.settings_path.len == 0) return;
    if (model.save_inflight) {
        model.save_dirty = true;
        return;
    }
    const bytes = settingsSnapshot(model) catch return;
    fx.writeFile(.{ .key = keys.save_settings, .path = model.settings_path, .bytes = bytes, .on_result = Effects.fileMsg(.saved) });
    model.save_inflight = true;
    model.save_dirty = false;
}

// Coalesce chatty saves (dragging the volume slider emits many changes).
fn scheduleSave(model: *Model, fx: *Effects) void {
    if (model.settings_path.len == 0) return;
    fx.startTimer(.{ .key = keys.save_debounce, .interval_ms = 800, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_save) });
}

fn scheduleReconnect(model: *Model, fx: *Effects) void {
    model.stream_failed = true;
    armAuthRecheck(model, fx);
    // Linux offers every mount optimistically (GStreamer decode support is
    // whatever plugins are installed) — a non-MP3 mount that keeps failing
    // drops to the floor instead of error-looping against a codec the host
    // can't play. macOS gates are exact, so its failures stay network-shaped
    // and never cost the listener their pick.
    if (builtin.os.tag == .linux and model.retry >= 3 and model.effectiveFormat() != .mp3) {
        model.format_pref = .mp3;
        saveSettings(model, fx);
    }
    // 500ms → 60s exponential backoff (ports web/hooks/usePlayer.ts).
    const shift: u5 = @intCast(@min(model.retry, 7));
    const delay: u32 = @min(@as(u32, 500) * (@as(u32, 1) << shift), 60_000);
    model.retry +|= 1;
    diag.print("stream reconnect retry={d} delay_ms={d} format={s}", .{ model.retry, delay, model.effectiveFormat().id() });
    fx.startTimer(.{ .key = keys.reconnect, .interval_ms = delay, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reconnect) });
}

// Ask the station whether `candidate` opens the privacy locks (POST
// /api/station-auth — fails closed; see api.stationAuth). The body lives in a
// model buffer because fetch bodies must outlive the frame (like
// like_body_buf); the URL is copied by the effect.
fn postStationAuth(model: *Model, fx: *Effects, candidate: []const u8, from_store: bool) void {
    var b: [256]u8 = undefined;
    const url = api.stationAuth(&b, model.base) catch return;
    setStr(&model.auth_try_buf, &model.auth_try, candidate);
    model.auth_from_store = from_store;
    model.auth_gate = .checking;
    model.auth_status = "";
    var w = std.Io.Writer.fixed(&model.auth_body_buf);
    std.json.Stringify.value(.{ .password = model.auth_try }, .{}, &w) catch return;
    model.auth_recheck.last_check = native_sdk.monotonicMs();
    fx.fetch(.{
        .key = keys.post_station_auth,
        .method = .POST,
        .url = url,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = w.buffered(),
        .timeout_ms = 10_000,
        .on_response = Effects.responseMsg(.got_station_auth),
    });
}

// A privacy lock engaged with no validated password: drop to the gate. The
// gate owns the whole window — one player surface at a time (PR #19), and an
// unauthenticated stream would just 401-loop against Icecast.
fn lockStation(model: *Model, fx: *Effects) void {
    model.auth_gate = .prompt;
    model.sheet = .none;
    model.mini_open = false;
    if (model.transport != .stopped) tuneOut(model, fx);
}

fn syncStationGate(model: *Model, fx: *Effects) void {
    if (!model.privacy_private and !model.privacy_listener_auth) {
        model.auth_gate = .idle;
        model.auth_status = "";
        model.auth_recheck_inflight = false;
        model.auth_recheck.reconnect_since = null;
        fx.cancel(keys.post_station_auth);
        fx.cancel(keys.post_auth_recheck);
        fx.cancelTimer(keys.auth_recheck_timer);
    } else if (!model.credentials_ready) {
        model.auth_gate = .checking;
    } else if (model.auth_gate == .idle) {
        if (model.station_pw.len > 0) {
            postStationAuth(model, fx, model.station_pw, true);
        } else {
            lockStation(model, fx);
            if (model.credentials_blocked)
                model.auth_status = "Couldn't read the saved password securely. Unlock the system keyring and restart, or enter the station password for this session.";
        }
    }
}

fn armAuthRecheck(model: *Model, fx: *Effects) void {
    // Only listenerAuth puts the password on the stream; a private-player-only
    // station's stalls are network trouble, not a rotated password.
    if (model.auth_gate != .ok or !model.privacy_listener_auth or
        model.station_pw.len == 0 or model.transport != .playing) return;
    if (model.auth_recheck.reconnect_since == null) {
        model.auth_recheck.reconnect_since = native_sdk.monotonicMs();
        fx.startTimer(.{ .key = keys.auth_recheck_timer, .interval_ms = 1000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_auth_recheck) });
    }
}

// Ask the station for the current airing's liked-state + count. A station
// without the endpoint (or with likes disabled) simply never flips
// like_available on, which keeps the heart hidden — correct for old stations.
fn fetchLikeStatus(model: *Model, fx: *Effects) void {
    var b: [256]u8 = undefined;
    if (api.like(&b, model.base)) |u| {
        if (!model.listener_fetches.start(model.listener_like_key, model.listener_like_generation)) {
            model.listener_like_deferred = true;
            return;
        }
        model.listener_like_deferred = false;
        fx.fetch(.{ .key = model.listener_like_key, .url = u, .on_response = Effects.responseMsg(.got_like_status) });
    } else |_| {}
}

fn likeCount(v: ?i64) u32 {
    const c = v orelse 0;
    return if (c <= 0) 0 else @intCast(@min(c, std.math.maxInt(u32)));
}

// Discord Rich Presence: (re)spawn the --discord-rpc-helper child whenever
// the payload it should be showing actually changes; cancel it outright when
// there is nothing to show. All state transitions are driven by the spawn's
// on_line/on_exit results (see the .discord_line/.discord_exited arms).
fn updateDiscordPresence(model: *Model, fx: *Effects) void {
    if (!model.discord_configured() or !model.discord_enabled) return cancelDiscordPresence(model, fx);
    if (model.transport != .playing and model.transport != .paused) return cancelDiscordPresence(model, fx);
    // No resolved own-binary path means nothing to spawn — without this,
    // a failed executablePath at startup would put the exit handler's
    // retry loop into a permanent spawn("")-and-fail cycle.
    if (model.self_exe_path.len == 0) return cancelDiscordPresence(model, fx);
    var cover_url_buf: [256]u8 = undefined;
    const cover_url = if (model.cover_sid.len > 0) api.coverUrl(&cover_url_buf, model.base, model.cover_sid) catch "" else "";
    const req: discord_rpc.ActivityRequest = .{
        .client_id = model.effectiveDiscordClientId(),
        .details = model.title,
        .state = model.presentation_artist(),
        .url = model.base,
        .cover_url = cover_url,
        .duration_s = model.track_duration_s,
        .elapsed_ms = model.track_elapsed_ms,
    };
    var sig_buf: [discord_rpc.activity_request_max]u8 = undefined;
    // elapsed_ms excluded from the signature on purpose — see
    // buildActivityRequestJson's doc comment. Only track/label/station
    // content should trigger a respawn, never time simply passing.
    const signature = discord_rpc.buildActivityRequestJson(&sig_buf, req, false) catch return;
    if (std.mem.eql(u8, signature, model.discord_last_payload)) return; // nothing meaningful changed
    respawnDiscordHelper(model, fx, signature, req);
}

fn cancelDiscordPresence(model: *Model, fx: *Effects) void {
    fx.cancel(model.discord_spawn_key);
    model.discord_last_payload = "";
    model.discord_connected = false;
}

// Helper ERROR lines → the static literals discord_status_line shows. Only
// the two actionable reasons get their own message; everything else (bad
// payload, encode/write failures) is an internal detail the listener can't
// act on beyond "it didn't work".
fn mapDiscordError(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "Discord not running")) return "Discord isn't running";
    if (std.mem.eql(u8, reason, "client id rejected")) return "Discord rejected the client ID";
    return "Connection to Discord failed";
}

fn respawnDiscordHelper(model: *Model, fx: *Effects, signature: []const u8, req: discord_rpc.ActivityRequest) void {
    // Build the stdin payload before touching any state: bailing out after
    // the cancel would kill the live helper without a replacement, and
    // committing the signature first would suppress the retry that could
    // have fixed it.
    var stdin_buf: [discord_rpc.activity_request_max]u8 = undefined;
    const stdin_payload = discord_rpc.buildActivityRequestJson(&stdin_buf, req, true) catch return;
    fx.cancel(model.discord_spawn_key);
    // Ping-pong the effect key: cancel() may leave the old slot draining
    // rather than immediately idle, and fx.spawn() rejects a same-tick
    // reuse of a still-active key. Alternating keys sidesteps that race
    // entirely instead of depending on internal drain timing.
    model.discord_spawn_key = if (model.discord_spawn_key == keys.discord_rpc_a) keys.discord_rpc_b else keys.discord_rpc_a;
    setStr(&model.discord_last_payload_buf, &model.discord_last_payload, signature);
    fx.spawn(.{
        .key = model.discord_spawn_key,
        .argv = &.{ model.self_exe_path, "--discord-rpc-helper" },
        .stdin = stdin_payload,
        .on_line = Effects.lineMsg(.discord_line),
        .on_exit = Effects.exitMsg(.discord_exited),
    });
}

fn scheduleDiscordRetry(model: *Model, fx: *Effects) void {
    const shift: u5 = @intCast(@min(model.discord_retry_count, 5));
    const delay: u32 = @min(@as(u32, 1000) * (@as(u32, 1) << shift), 30_000);
    model.discord_retry_count +|= 1;
    fx.startTimer(.{ .key = keys.discord_retry, .interval_ms = delay, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_discord_retry) });
}

// Push a station onto the MRU recents list (dedupe by url, cap 8). Each row
// owns its own store buffers, so shifting backward row-by-row never overlaps.
fn pushRecent(model: *Model, name: []const u8, url: []const u8) void {
    var existing: ?usize = null;
    for (model.recents[0..model.recents_count], 0..) |r, i| {
        if (std.mem.eql(u8, r.url, url)) {
            existing = i;
            break;
        }
    }
    // Rows [0..shift_end) move down one slot; the duplicate (or the overflow
    // tail) is overwritten.
    const shift_end = existing orelse @min(model.recents_count, max_recents - 1);
    var i: usize = shift_end;
    while (i > 0) : (i -= 1) {
        setStr(&model.recents_name_store[i], &model.recents[i].name, model.recents[i - 1].name);
        setStr(&model.recents_url_store[i], &model.recents[i].url, model.recents[i - 1].url);
    }
    setStr(&model.recents_name_store[0], &model.recents[0].name, if (name.len > 0) name else url);
    setStr(&model.recents_url_store[0], &model.recents[0].url, url);
    if (existing == null) model.recents_count = @min(model.recents_count + 1, max_recents);
}

// Drop a station from the recents list by url (the sidebar's per-row remove).
// Rows after it shift up one slot into their own store buffers — the mirror
// of pushRecent's shift-down. An unknown url is a no-op.
fn forgetRecent(model: *Model, url: []const u8) bool {
    var found: ?usize = null;
    for (model.recents[0..model.recents_count], 0..) |r, i| {
        if (std.mem.eql(u8, r.url, url)) {
            found = i;
            break;
        }
    }
    const at = found orelse return false;
    var i: usize = at;
    while (i + 1 < model.recents_count) : (i += 1) {
        setStr(&model.recents_name_store[i], &model.recents[i].name, model.recents[i + 1].name);
        setStr(&model.recents_url_store[i], &model.recents[i].url, model.recents[i + 1].url);
    }
    model.recents_count -= 1;
    model.recents[model.recents_count] = .{};
    return true;
}

// Forget the current cover art: kill any load still in flight and release the
// registered pixels. Leaves `cover_sid` alone — the caller decides whether the
// track identity is also stale. `cover_id` 0 is the honest state while nothing
// is loaded: the stage falls back to the initials disc.
fn dropCover(model: *Model, fx: *Effects) void {
    if (model.cover_loading_id != 0) {
        fx.cancel(model.cover_loading_id);
        model.cover_loading_id = 0;
    }
    if (model.cover_id != 0) {
        _ = fx.unregisterImage(model.cover_id);
        model.cover_id = 0;
    }
}

// Start loading the art for `sid`. One load at a time: the previous one is
// cancelled, and the id is minted here (it is both the ImageId the stage draws
// and the effect key) but only promoted to `cover_id` when the runtime reports
// the pixels registered — a failed load leaves the initials disc standing.
fn loadCover(model: *Model, fx: *Effects, sid: []const u8) void {
    dropCover(model, fx);
    const url = api.coverUrl(&model.cover_url_buf, model.base, sid) catch return;
    const id = model.next_cover_id;
    model.next_cover_id = if (id + 1 >= keys.persona_image_base) keys.cover_image_base else id + 1;
    // Cache into the OS caches dir when we know where that is. An unresolved
    // cache_dir (or a path that will not fit the buffer) just means this load
    // goes to the network like it always did — never a reason to skip the art.
    const cache_path: []const u8 = if (model.cache_dir.len > 0)
        native_sdk.imageCachePath(&model.cover_cache_buf, model.cache_dir, url) catch ""
    else
        "";
    fx.loadImage(.{
        .id = id,
        .url = url,
        .cache_path = cache_path,
        .on_result = Effects.imageMsg(.got_cover),
    });
    model.cover_loading_id = id;
}

fn resetScheduleDisclosures(model: *Model) void {
    model.slot_topic_open = [_]bool{false} ** 24;
    model.slot_host_open = [_]bool{false} ** 24;
    model.now_topic_open = false;
    model.now_host_open = false;
}

fn dropPersonas(model: *Model, fx: *Effects) void {
    for (0..station_schedule.max_personas) |i| {
        if (model.persona_loading[i] != 0) fx.cancel(model.persona_loading[i]);
        if (model.persona_images[i] != 0) _ = fx.unregisterImage(model.persona_images[i]);
        model.persona_loading[i] = 0;
        model.persona_images[i] = 0;
    }
}

fn loadPersonas(model: *Model, fx: *Effects) void {
    for (model.persona_roster.rows[0..model.persona_roster.count], 0..) |p, i| {
        if (p.avatar.len == 0) continue;
        const url = api.personaAvatarUrl(&model.persona_url_store[i], model.base, p.avatar) catch continue;
        const id = model.next_persona_id;
        model.next_persona_id += 1;
        const cache_path: []const u8 = if (model.cache_dir.len > 0)
            native_sdk.imageCachePath(&model.persona_cache_store[i], model.cache_dir, url) catch ""
        else
            "";
        fx.loadImage(.{ .id = id, .url = url, .cache_path = cache_path, .on_result = Effects.imageMsg(.got_persona) });
        model.persona_loading[i] = id;
    }
}

// Re-point everything at a (possibly new) station base: fresh stream + feeds,
// nothing left over from the old one. `url` must already be normalized into
// model.base by the caller.
fn retune(model: *Model, fx: *Effects) void {
    fx.cancel(model.listener_np_key);
    fx.cancel(model.listener_state_key);
    fx.cancel(model.listener_session_key);
    fx.cancel(model.listener_like_key);
    model.listener_generation +%= 1;
    model.listener_like_generation +%= 1;
    model.listener_feed_deferred = false;
    model.listener_like_deferred = false;
    // Old terminal responses can already be queued when cancellation runs.
    // Each station uses the other pair so they cannot complete its feed join.
    const use_a = model.listener_np_key != keys.listener_np_a;
    model.listener_np_key = if (use_a) keys.listener_np_a else keys.listener_np_b;
    model.listener_state_key = if (use_a) keys.listener_state_a else keys.listener_state_b;
    model.listener_session_key = if (use_a) keys.listener_session_a else keys.listener_session_b;
    model.listener.reset();
    model.raw_booth_count = 0;
    model.dj_talking = false;
    cancelRequestReturn(model, fx);
    // The switch closes the list; cancel its old station probes as well.
    syncDirectoryStatus(model, fx, true);
    dropCover(model, fx);
    dropPersonas(model, fx);
    model.persona_roster.count = 0;
    model.timezone = "";
    model.station_locale = .en_gb;
    model.station_offset_minutes = 0;
    model.day_picked = false;
    model.day_sel = model.stationDay();
    resetScheduleDisclosures(model);
    model.host_id = "";
    model.now_guests = "";
    model.station_loc = "";
    model.cover_sid = "";
    model.title = "Tuning in…";
    model.artist = "";
    model.album = "";
    model.genre = "";
    model.dj = "";
    model.show = "";
    model.host = "";
    model.listeners = 0;
    model.booth_line = "";
    model.booth_count = 0;
    model.show_count = 0;
    model.upcoming_count = 0;
    model.history_count = 0;
    model.sched_grid = [_][24]u8{[_]u8{0} ** 24} ** 7;
    model.req_id = "";
    model.req_status = "";
    model.req_phase = .idle;
    model.stream_failed = false;
    model.retry = 0;
    model.latency_ms = -1;
    model.probe_fails = 0;
    model.probe_inflight = false;
    model.track_year = 0;
    model.track_duration_s = 0;
    model.track_started_at_s = 0;
    model.track_anchor_ms = 0;
    model.track_elapsed_ms = 0;
    model.track_bpm = 0;
    model.musical_key = "";
    model.moods = "";
    model.energy = "";
    model.llm_tokens = 0;
    model.ctx_show = "";
    model.ctx_vibe = "";
    model.ctx_cond = "";
    model.ctx_temp = -999;
    model.ctx_festival = "";
    model.like_song = "";
    model.like_available = false;
    model.like_liked = false;
    model.like_pending = false;
    model.like_count = 0;
    // Only this station's remembered format and password can carry over.
    restoreStationSettings(model);
    model.stream_flags_known = false;
    model.stream_opus = false;
    model.stream_flac = false;
    model.stream_aac = false;
    model.stream_primary = null;
    model.stream_bitrate = 0;
    model.auth_recheck = .{};
    model.auth_recheck_inflight = false;
    fx.cancelTimer(keys.auth_recheck_timer);
    fx.cancel(keys.post_auth_recheck);
    model.pw_buffer.clear();
    model.privacy_private = false;
    model.privacy_listener_auth = false;
    model.auth_gate = .idle;
    model.auth_status = "";
    fx.cancel(keys.post_station_auth);
    // Cancel everything still in flight for the OLD station so a late
    // response can't repopulate the fresh state.
    fx.cancel(keys.fetch_np);
    fx.cancel(keys.fetch_state);
    fx.cancel(keys.fetch_session);
    fx.cancel(keys.fetch_themes);
    // (the cover load, whose key is its ImageId, was cancelled by dropCover)
    fx.cancel(keys.fetch_like);
    fx.cancel(keys.post_like);
    fx.cancel(keys.fetch_schedule);
    fx.cancel(keys.fetch_health);
    fx.cancel(keys.fetch_dj);
    fx.cancel(keys.post_request);
    fx.cancel(keys.fetch_reqstat);
    fx.cancelTimer(keys.request_poll);
    fx.cancelTimer(keys.reconnect);
    fx.stopAudio();
    startStream(model, fx); // also (re)spawns Discord Rich Presence for the new station
    fetchFeed(model, fx);
    fetchThemes(model, fx);
    fetchSchedule(model, fx);
    fetchDj(model, fx);
    postBeacon(model, fx);
    saveSettings(model, fx);
}

// The one writer of track_elapsed_ms — see the field docs. The wall clock
// arrives as a parameter so tests can pin it.
fn refreshTrackElapsed(model: *Model, now_wall_ms: i64) void {
    const audible_at = (if (model.listener.clock_from_server) model.listener.audible_at_ms else null) orelse
        if (model.track_started_at_s > 0) (model.track_started_at_s *| 1000) +| model.listener.lead_ms else null;
    model.track_elapsed_ms = listener_time.elapsedMs(
        if (audible_at != null) now_wall_ms else model.elapsed_ms,
        audible_at orelse model.track_anchor_ms,
        model.track_duration_s *| 1000,
    );
}

fn trackInput(track: json.Track, moods: *[96]u8) listener_time.Track {
    var length: usize = 0;
    for (track.moods orelse &.{}, 0..) |mood, i| {
        if (i >= 3) break;
        const sep: []const u8 = if (i > 0) " · " else "";
        if (length + sep.len + mood.len > moods.len) break;
        @memcpy(moods[length..][0..sep.len], sep);
        length += sep.len;
        @memcpy(moods[length..][0..mood.len], mood);
        length += mood.len;
    }
    return .{
        .title = track.title orelse "",
        .artist = track.artist orelse "",
        .album = track.album orelse "",
        .genre = track.genre orelse "",
        .song_id = track.subsonic_id orelse "",
        .musical_key = track.musicalKey orelse "",
        .moods = moods[0..length],
        .energy = track.energy orelse "",
        .year = track.year orelse 0,
        .duration_s = if (track.duration) |d| displayInteger(@max(0, d), 0) else 0,
        .bpm = if (track.bpm) |b| displayInteger(@round(b), 0) else 0,
        .legacy_start_ms = if (track.timestamp) |stamp| stamp *| 1000 else null,
    };
}

fn publishTrack(model: *Model, fx: *Effects, publication: listener_time.Publication) void {
    const track = publication.track orelse listener_time.Track{};
    const changed = !std.mem.eql(u8, model.title, track.title) or !std.mem.eql(u8, model.artist, track.artist);
    setStr(&model.title_buf, &model.title, track.title);
    setStr(&model.artist_buf, &model.artist, track.artist);
    setStr(&model.album_buf, &model.album, track.album);
    setStr(&model.genre_buf, &model.genre, track.genre);
    setStr(&model.key_buf, &model.musical_key, track.musical_key);
    setStr(&model.moods_buf, &model.moods, track.moods);
    setStr(&model.energy_buf, &model.energy, track.energy);
    model.track_year = track.year;
    model.track_duration_s = track.duration_s;
    model.track_bpm = track.bpm;
    model.track_started_at_s = if (track.legacy_start_ms) |stamp| @divTrunc(stamp, 1000) else 0;
    if (changed) model.track_anchor_ms = model.elapsed_ms;
    if (!std.mem.eql(u8, track.song_id, model.cover_sid)) {
        setStr(&model.cover_sid_buf, &model.cover_sid, track.song_id);
        if (track.song_id.len > 0) loadCover(model, fx, track.song_id) else dropCover(model, fx);
    }
    if (!std.mem.eql(u8, track.song_id, model.like_song) or (changed and publication.changed)) {
        fx.cancel(model.listener_like_key);
        model.listener_like_generation +%= 1;
        model.listener_like_deferred = false;
        model.listener_like_key = if (model.listener_like_key == keys.listener_like_a) keys.listener_like_b else keys.listener_like_a;
        fx.cancel(keys.post_like);
        setStr(&model.like_song_buf, &model.like_song, track.song_id);
        model.like_available = false;
        model.like_liked = false;
        model.like_pending = false;
        model.like_count = 0;
        if (track.song_id.len > 0) fetchLikeStatus(model, fx);
    }
    if (publication.changed and !publication.first and model.shouldNotifyTrack())
        fx.showNotification(model.trackNotification());
}

fn numberValue(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn decodeBoothTurn(turn: *listener_time.Turn, message: json.SessionMsg) void {
    turn.* = .{};
    const role = message.role orelse "";
    const kind = message.kind orelse "";
    const text = message.text orelse "";
    const meta = message.meta orelse json.SessionMeta{};
    turn.class = listener_time.turnClass(role);
    turn.voice = listener_time.isVoice(role, kind);
    turn.boundary = std.mem.eql(u8, role, "event") and std.mem.eql(u8, kind, "show-boundary");
    if (meta.carried) |carried| turn.carried = carried == .bool and carried.bool;
    turn.text.set(text);
    turn.persona.set(meta.personaName orelse "");
    turn.track_id.set(meta.trackId orelse "");
    turn.duration_ms = listener_time.lineMs(numberValue(meta.durationMs), text);
    if (message.t) |stamp| switch (stamp) {
        .string => |value| {
            turn.stamp.set(value);
            turn.stamp_ms = iso8601.parseMs(value);
        },
        .integer => |value| turn.stamp_ms = value,
        .float => |value| {
            if (std.math.isFinite(value) and value >= -0x1p63 and value < 0x1p63)
                turn.stamp_ms = @intFromFloat(value);
        },
        else => {},
    };
    if (meta.airedAt) |stamp| {
        if (stamp == .string) turn.aired_at_ms = iso8601.parseMs(stamp.string);
    }
    if (meta.boundary) |boundary| {
        turn.boundary_at.set(boundary.at orelse "");
        const show = boundary.show orelse "";
        const persona = boundary.persona orelse "";
        turn.boundary_name.set(if (show.len > 0) show else if (persona.len > 0) persona else "On air");
    }
}

// Legacy UTC hh:mm kept on the row; the panel renders station_stamp.
fn boothStamp(stamp: []const u8) []const u8 {
    return isoToHhmm(stamp);
}

fn refreshBooth(model: *Model, now_ms: i64) void {
    model.booth_line = "";
    model.booth_count = 0;
    var index = model.raw_booth_count;
    while (index > 0) {
        index -= 1;
        const raw = &model.raw_booth[index];
        if (!raw.visible(model.listener.lead_ms, now_ms)) continue;
        if (model.booth_line.len == 0 and raw.ticker(model.like_song))
            setStr(&model.booth_buf, &model.booth_line, raw.text.slice());
        if (model.booth_count >= max_booth or (raw.class == .system and !raw.boundary)) continue;
        var body = raw.text.slice();
        var boundary_buf: [240]u8 = undefined;
        if (raw.boundary) {
            if (iso8601.parseMs(raw.boundary_at.slice())) |at_ms| {
                var clock_buf: [32]u8 = undefined;
                const at = station_time.clock(&clock_buf, at_ms, model.station_offset_minutes, model.station_locale, false);
                body = std.fmt.bufPrint(&boundary_buf, "{s} · {s}", .{ at, raw.boundary_name.slice() }) catch body;
            }
        }
        if (body.len == 0) continue;
        if (raw.class == .track and std.mem.startsWith(u8, body, "▶"))
            body = std.mem.trimStart(u8, body["▶".len..], " \t\r\n");
        const slot = model.booth_count;
        const turn = &model.booth_turns[slot];
        turn.* = .{
            .is_voice = raw.class == .voice,
            .is_track = raw.class == .track,
            .is_carried = raw.carried,
            .is_boundary = raw.boundary,
            .kind = switch (raw.class) {
                .voice => "VOICE",
                .dj => "PICK",
                .track => "TRACK",
                .system => "SHOW",
            },
        };
        setStr(&model.booth_time_store[slot], &turn.hhmm, boothStamp(raw.stamp.slice()));
        // The controller stamps turns in ISO; a bare number keeps station_time's
        // seconds-or-milliseconds reading.
        turn.stamp_epoch_s = if (raw.stamp.slice().len > 0)
            (if (raw.stamp_ms) |ms| @divFloor(ms, 1000) else null)
        else if (raw.stamp_ms) |v| station_time.timestamp(.{ .integer = v }) else null;
        setStr(&model.booth_text_store[slot], &turn.text, body);
        setStr(&model.booth_persona_store[slot], &turn.persona, raw.persona.slice());
        model.booth_count += 1;
    }
    model.dj_talking = listener_time.talkingState(model.raw_booth[0..model.raw_booth_count], model.listener.lead_ms, now_ms).talking;
}

fn refreshListener(model: *Model, fx: *Effects, now_ms: i64) void {
    if (model.listener.advance(now_ms)) |publication| publishTrack(model, fx, publication);
    refreshBooth(model, now_ms);
    refreshTrackElapsed(model, now_ms);
    refreshTrayStatus(model);
    updateDiscordPresence(model, fx);
}

// f64 rounds maxInt(i64) up to 2^63, so the upper bound must be exclusive.
// Invalid station numbers retain the field's existing unknown-value sentinel.
fn displayInteger(value: f64, fallback: i64) i64 {
    if (!std.math.isFinite(value) or value < -0x1p63 or value >= 0x1p63) return fallback;
    return @intFromFloat(value);
}

// "Title — Artist" + "0:52 · on air · 2 listening" — the tray's two
// disabled now-playing rows.
fn refreshTrayStatus(model: *Model) void {
    const artist = model.presentation_artist();
    if (artist.len > 0) {
        if (std.fmt.bufPrint(&model.tray_track_buf, "{s} — {s}", .{ model.title, artist })) |line| {
            model.tray_track = line;
        } else |_| {
            model.tray_track = model.title;
        }
    } else {
        model.tray_track = model.title;
    }
    const secs: u64 = @intCast(@max(0, @divTrunc(model.track_elapsed_ms, 1000)));
    if (std.fmt.bufPrint(&model.tray_status_buf, "{d}:{d:0>2} · {s} · {d} listening", .{
        secs / 60,
        secs % 60,
        model.status_word(),
        model.listeners,
    })) |line| {
        model.tray_status = line;
    } else |_| {}
}

fn startPlayerTimers(model: *Model, fx: *Effects) void {
    fx.startTimer(.{ .key = keys.listener_timer, .interval_ms = 1000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_listener) });
    syncPolling(model, fx);
}

fn syncSecondTimer(model: *Model, fx: *Effects) void {
    const needed = model.sleep_deadline_ms > 0 or
        (model.phase == .player and model.app_active and !model.mini_open and (model.active_tab == .schedule or model.active_tab == .timeline));
    if (needed == model.station_second_timer_active) return;
    model.station_second_timer_active = needed;
    if (needed)
        fx.startTimer(.{ .key = keys.second_timer, .interval_ms = 1000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_second) })
    else
        fx.cancelTimer(keys.second_timer);
}

fn armSleep(model: *Model, fx: *Effects, minutes: i64) void {
    model.sleep_minutes = minutes;
    model.now_wall_ms = native_sdk.nowMs();
    model.sleep_deadline_ms = model.now_wall_ms + minutes * 60_000;
    fx.startTimer(.{ .key = keys.second_timer, .interval_ms = 1000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_second) });
    model.station_second_timer_active = true;
}

fn disarmSleep(model: *Model, fx: *Effects) void {
    model.sleep_deadline_ms = 0;
    model.sleep_minutes = 0;
    syncSecondTimer(model, fx);
}

fn tuneOut(model: *Model, fx: *Effects) void {
    diag.print("stream stop", .{});
    fx.stopAudio();
    // Tuning out ends any reconnect story: without this a prior failure would
    // keep the "STREAM LOST" banner up over a deliberately stopped player.
    fx.cancelTimer(keys.reconnect);
    model.transport = .stopped;
    model.stream_failed = false;
    model.buffering = false;
    model.retry = 0;
    model.latency_ms = -1;
    model.probe_fails = 0;
    model.auth_recheck.reconnect_since = null;
    model.auth_recheck_inflight = false;
    fx.cancelTimer(keys.auth_recheck_timer);
    fx.cancel(keys.post_auth_recheck);
    updateDiscordPresence(model, fx);
}

// Start the onboarding health-check against a candidate url/name.
fn obStart(model: *Model, fx: *Effects, raw: []const u8, name: []const u8) void {
    var buf: [256]u8 = undefined;
    const normalized = api.normalizeBase(&buf, raw) catch |err| {
        model.station_status = if (err == error.StationLoginUnsupported)
            "HTTP Basic Station login is not supported by this desktop player. Use a URL without a proxy login."
        else
            "That address doesn't look right. Enter an HTTP or HTTPS station URL.";
        return;
    };
    fx.cancel(keys.fetch_ob_health);
    fx.cancel(keys.fetch_ob_fallback);
    fx.cancel(keys.fetch_ob_dj);
    fx.cancelTimer(keys.ob_step_timer);
    setStr(&model.ob_target_url_buf, &model.ob_target_url, normalized);
    setStr(&model.ob_target_name_buf, &model.ob_target_name, if (name.len > 0) name else normalized);
    model.ob_allow_fallback = !station_access.hasScheme(raw) and std.mem.startsWith(u8, normalized, "https://");
    model.ob_tried_https = std.mem.startsWith(u8, normalized, "https://");
    model.ob_checking = true;
    model.ob_done = false;
    model.ob_diag = "";
    model.ob_raw = "";
    model.ob_insecure = false;
    model.station_status = "";
    model.ob_steps = .{ .run, .wait, .wait, .wait };
    if (model.ob_from_sidebar) model.phase = .onboarding;
    fx.startTimer(.{ .key = keys.ob_step_timer, .interval_ms = 420, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_ob_step) });
}

fn fetchObHealth(model: *Model, fx: *Effects, key: u64) void {
    var b: [256]u8 = undefined;
    if (api.health(&b, model.ob_target_url)) |u| {
        fx.fetch(.{ .key = key, .url = u, .timeout_ms = 4500, .on_response = Effects.responseMsg(.got_ob_health) });
    } else |_| {
        model.ob_steps[1] = .fail;
        setStr(&model.ob_diag_buf, &model.ob_diag, "That address doesn't look right.");
    }
}

fn finishOnboarding(model: *Model, fx: *Effects) void {
    var buf: [256]u8 = undefined;
    const b = api.normalizeBase(&buf, model.ob_target_url) catch return;
    rememberStationSettings(model);
    setStr(&model.base_buf, &model.base, b);
    setStr(&model.station_name_buf, &model.station_name, model.ob_target_name);
    pushRecent(model, model.station_name, model.base);
    model.station_buffer.clear();
    model.phase = .player;
    diag.print("phase player (onboarding complete)", .{});
    model.ob_checking = false;
    model.ob_from_sidebar = false;
    model.ob_insecure = false;
    model.sidebar_open = false;
    model.day_sel = model.stationDay();
    startPlayerTimers(model, fx);
    retune(model, fx);
}

// ------------------------------------------------------------------ boot
pub fn boot(model: *Model, fx: *Effects) void {
    if (model.phase == .player) pushRecent(model, model.station_name, model.base);
    rememberStationSettings(model);
    if (model.use_secure_credentials) {
        model.credentials_ready = false;
        fx.credentialsGet(.{ .key = keys.station_credentials, .credential_key = station_access.vault_key, .on_result = Effects.credentialsMsg(.got_station_credentials) });
    } else saveSettings(model, fx);
    // Station-independent, so it runs in both phases; the repeating timer
    // matters because close_policy = hide keeps the app resident for weeks.
    checkForUpdate(fx);
    fx.startTimer(.{ .key = keys.update_timer, .interval_ms = 86_400_000, .mode = .repeating, .on_fire = Effects.timerMsg(.tick_update) });
    fetchDirectory(fx); // Discover rows for onboarding + sidebar
    if (model.phase == .player) {
        startStream(model, fx);
        fetchFeed(model, fx);
        fetchThemes(model, fx);
        fetchSchedule(model, fx);
        fetchDj(model, fx);
        postBeacon(model, fx);
        startPlayerTimers(model, fx);
        model.day_sel = model.stationDay();
        syncSecondTimer(model, fx);
    } else {
        model.transport = .stopped;
    }
    syncDirectoryStatus(model, fx, true);
}

// ---------------------------------------------------------------- update
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    defer syncPolling(model, fx);
    defer syncDirectoryStatus(model, fx, false);
    // While the privacy gate is up, transport/mini/like verbs are dead —
    // the gate owns the window, and an unauthenticated stream would just
    // 401-loop against Icecast. (Keyboard fallbacks land here too.)
    if (model.station_locked()) switch (msg) {
        .toggle_play, .tune_toggle, .toggle_mute, .press_like, .toggle_mini, .expand_mini, .sleep_cycle => return,
        else => {},
    };
    switch (msg) {
        .tick_feed => |t| {
            if (t.outcome != .fired or pollCadence(model).now_playing_ms == 0) return;
            // fetchFeed runs on EVERY fired tick regardless of the heartbeat
            // cadence below — the poll must not be coupled to diagnostics.
            //
            // The heartbeat itself only emits every 12th fired tick (60s in
            // foreground, 120s in background). At the 5s cadence this used to run
            // at, a ~72-byte line every tick fills diag's 256 KB cap in about
            // 3640 beats — just over 5 hours — which would silence the log
            // long before issue #23's multi-day sessions ever hang. Slowing to
            // 60s buys roughly 12x the headroom. audio_events keeps
            // accumulating across the whole 60s window and only resets when
            // the heartbeat actually fires, so no audio_event Msg is ever
            // dropped from the count between emissions.
            model.hb_tick_count +|= 1;
            if (model.hb_tick_count >= 12) {
                model.hb_tick_count = 0;
                // A gap in these lines is how a stalled message loop shows up
                // in the log, and audio_events reading zero while they
                // continue separates a dead feed from a dead loop. See
                // src/diag.zig and issue #23.
                diag.print("hb phase={s} transport={s} audio_events={d} retry={d}", .{
                    @tagName(model.phase),
                    @tagName(model.transport),
                    model.hb_audio_events,
                    model.retry,
                });
                model.hb_audio_events = 0;
            }
            if (feedActive(model)) fetchFeed(model, fx) else fetchTrack(model, fx);
        },
        .tick_background_feed => |t| {
            if (t.outcome == .fired and !feedActive(model) and pollCadence(model).session_ms > 0)
                fetchSession(model, fx);
        },
        .tick_directory_status => |t| {
            if (t.outcome != .fired or !directoryVisible(model)) return;
            model.directory_status.refresh();
            pumpDirectoryStatus(model, fx);
        },
        .got_directory_status => |r| {
            if (r.key < keys.directory_status_base or r.key >= keys.directory_status_base + station_status.capacity) return;
            const entry = &model.directory_status.entries[r.key - keys.directory_status_base];
            if (!entry.pending) return;
            entry.pending = false;
            if (r.outcome == .cancelled and entry.wanted and directoryVisible(model)) entry.waiting = true;
            if (directoryVisible(model) and entry.wanted and r.outcome != .cancelled and r.outcome != .rejected) {
                entry.setStatus(false, "", "");
                if (r.outcome == .ok and r.status == 200 and !r.truncated) {
                    const parsed = json.parse(json.NowPlaying, std.heap.page_allocator, r.body) catch {
                        pumpDirectoryStatus(model, fx);
                        return;
                    };
                    defer parsed.deinit();
                    const np = parsed.value;
                    const tr = np.nowPlaying orelse json.Track{};
                    entry.setStatus(np.streamOnline orelse true, tr.artist orelse "", tr.title orelse "");
                }
            }
            pumpDirectoryStatus(model, fx);
        },
        .tick_reconnect => |t| {
            if (t.outcome == .fired and model.transport == .playing) startStream(model, fx);
        },
        .tick_theme => |t| {
            if (t.outcome == .fired and pollCadence(model).themes_ms > 0) fetchThemes(model, fx);
        },
        .tick_update => |t| {
            if (t.outcome == .fired) checkForUpdate(fx);
        },
        .got_update => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.Release, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            if (parsed.value.tag_name) |tag| {
                if (updater.isNewer(tag)) setStr(&model.update_tag_buf, &model.update_tag, tag) else model.update_tag = "";
            }
        },
        .open_release => openLink(model, fx, keys.open_release_spawn, links.open_release_argv),
        .open_support => openLink(model, fx, keys.open_support_spawn, links.open_support_argv),
        .opener_exited => model.opener_inflight = false,
        .tick_signal => |t| {
            if (t.outcome != .fired) return;
            if (pollCadence(model).signal_ms == 0 or model.probe_inflight) return;
            var b: [256]u8 = undefined;
            if (api.health(&b, model.base)) |u| {
                model.probe_t0 = native_sdk.monotonicMs();
                model.probe_inflight = true;
                fx.fetch(.{ .key = keys.fetch_health, .url = u, .timeout_ms = 4000, .on_response = Effects.responseMsg(.got_health) });
            } else |_| {}
        },
        .got_health => |r| {
            model.probe_inflight = false;
            if (r.outcome == .ok and r.status < 400) {
                model.latency_ms = @intCast(native_sdk.monotonicMs() - model.probe_t0);
                model.probe_fails = 0;
                if (model.probe_slow) {
                    // Back to the brisk cadence after recovery.
                    model.probe_slow = false;
                }
            } else {
                model.probe_fails +|= 1;
                model.latency_ms = -1;
                if (model.probe_fails >= probe_backoff_after and !model.probe_slow) {
                    // The link is just down — probe gently instead of hammering.
                    model.probe_slow = true;
                }
            }
        },
        .tick_second => |t| {
            if (t.outcome != .fired) return;
            model.now_wall_ms = native_sdk.nowMs();
            if (!model.day_picked and model.day_sel != model.stationDay()) {
                model.day_sel = model.stationDay();
                resetScheduleDisclosures(model);
            }
            if (model.sleep_deadline_ms > 0 and model.now_wall_ms >= model.sleep_deadline_ms) {
                disarmSleep(model, fx);
                tuneOut(model, fx);
            }
        },
        .tick_listener => |t| {
            if (t.outcome == .fired) refreshListener(model, fx, native_sdk.nowMs());
        },
        .got_np => |r| {
            const current_reply = model.listener_fetches.finish(r.key, model.listener_generation);
            if (!current_reply or r.key != model.listener_np_key) {
                if (model.listener_feed_deferred) fetchFeed(model, fx);
                return;
            }
            if (r.outcome != .ok or r.status != 200) {
                model.listener.failTrack();
                refreshListener(model, fx, native_sdk.nowMs());
                return;
            }
            const parsed = json.parse(json.NowPlaying, std.heap.page_allocator, r.body) catch {
                model.listener.failTrack();
                refreshListener(model, fx, native_sdk.nowMs());
                return;
            };
            defer parsed.deinit();
            const np = parsed.value;
            if (np.timezone) |v| setStr(&model.timezone_store, &model.timezone, v);
            if (np.locale) |v| model.station_locale = station_time.locale(v);
            const ctx_clock = if (np.context) |c| c.clock else null;
            const ctx_date = if (np.context) |c| c.date else null;
            model.station_offset_minutes = station_time.offset(model.station_clock.wallMs(), if (ctx_clock) |c| c.hhmm else null, if (ctx_date) |d| d.dayOfWeek else null);
            if (!model.day_picked and model.day_sel != model.stationDay()) {
                model.day_sel = model.stationDay();
                resetScheduleDisclosures(model);
            }
            const now_ms = native_sdk.nowMs();
            var moods: [96]u8 = undefined;
            model.listener.receiveTrack(if (np.nowPlaying) |track| trackInput(track, &moods) else null, if (np.stream) |stream| numberValue(stream.bufferSeconds) else null, now_ms);
            if (np.context) |ctx| {
                model.ctx_festival = "";
                if (ctx.festival) |festival| if (festival.name) |name| {
                    setStr(&model.ctx_festival_store, &model.ctx_festival, name);
                };
                if (ctx.time) |tc| {
                    setStr(&model.ctx_show_buf, &model.ctx_show, tc.show orelse "");
                    setStr(&model.ctx_vibe_buf, &model.ctx_vibe, tc.vibe orelse "");
                } else {
                    model.ctx_show = "";
                    model.ctx_vibe = "";
                }
                if (ctx.weather) |wc| {
                    setStr(&model.ctx_cond_buf, &model.ctx_cond, wc.condition orelse "");
                    if (wc.temp) |v| model.ctx_temp = displayInteger(@round(v), -999);
                    if (wc.location) |v| setStr(&model.station_loc_buf, &model.station_loc, v);
                } else model.ctx_cond = "";
            } else {
                model.ctx_festival = "";
                model.ctx_show = "";
                model.ctx_vibe = "";
                model.ctx_cond = "";
            }
            if (np.dj) |d| {
                if (d.name) |v| setStr(&model.dj_buf, &model.dj, v);
            }
            if (np.activeShow) |s| {
                if (!std.mem.eql(u8, s.name orelse "", model.show) or !std.mem.eql(u8, if (s.persona) |p| p.id orelse "" else "", model.host_id)) {
                    model.now_topic_open = false;
                    model.now_host_open = false;
                }
                model.host_id = "";
                model.now_guests = "";
                if (s.name) |v| setStr(&model.show_buf, &model.show, v);
                if (s.persona) |p| {
                    if (p.name) |v| setStr(&model.host_buf, &model.host, v);
                    if (p.id) |v| setStr(&model.host_id_store, &model.host_id, v);
                } else model.host = "";
                if (s.guests) |guests| {
                    var writer = std.Io.Writer.fixed(&model.now_guests_store);
                    var count: usize = 0;
                    for (guests) |g| {
                        const name = g.name orelse continue;
                        if (name.len == 0) continue;
                        writer.print("{s}{s}", .{ if (count > 0) @as([]const u8, " & ") else "", name }) catch break;
                        count += 1;
                    }
                    model.now_guests = writer.buffered();
                }
            } else {
                model.show = "";
                model.host = "";
                model.host_id = "";
                model.now_guests = "";
            }
            if (np.listeners) |l| {
                if (l.current) |c| model.listeners = c;
            }
            if (np.llmTokens) |tok| model.llm_tokens = tok;
            // Optional-mount flags. When they move the effective format —
            // the operator turned the picked mount off (or back on), or the
            // optimistic pre-poll pick turned out wrong — the live stream
            // follows right away instead of error-looping on a dead mount.
            if (np.stream) |sf| {
                const before = model.effectiveFormat();
                model.stream_flags_known = true;
                model.stream_opus = sf.opusEnabled orelse false;
                model.stream_flac = sf.flacEnabled orelse false;
                model.stream_aac = sf.aacEnabled orelse false;
                // The primary mount's shape, for the deck chip's readout. An
                // unrecognised format id leaves the pair unset rather than
                // pinning the bitrate to the wrong mount.
                model.stream_primary = if (sf.format) |id| stream_format.fromId(id) else null;
                model.stream_bitrate = if (model.stream_primary != null and sf.bitrate != null and
                    sf.bitrate.? > 0 and sf.bitrate.? < 10_000)
                    @intCast(sf.bitrate.?)
                else
                    0;
                if (model.transport == .playing and model.effectiveFormat() != before)
                    startStream(model, fx);
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
            refreshListener(model, fx, now_ms);
        },
        .got_state => |r| {
            const current_reply = model.listener_fetches.finish(r.key, model.listener_generation);
            if (!current_reply or r.key != model.listener_state_key) {
                if (model.listener_feed_deferred) fetchFeed(model, fx);
                return;
            }
            defer refreshListener(model, fx, native_sdk.nowMs());
            if (r.outcome != .ok or r.status != 200) {
                model.listener.receiveCurrent(null);
                return;
            }
            const parsed = json.parse(json.StationState, std.heap.page_allocator, r.body) catch {
                model.listener.receiveCurrent(null);
                return;
            };
            defer parsed.deinit();
            model.listener.receiveCurrent(if (parsed.value.current) |current| .{
                .title = current.title orelse "",
                .artist = current.artist orelse "",
                .song_id = current.subsonic_id orelse "",
                .started_at_ms = if (current.startedAt) |stamp| iso8601.parseMs(stamp) else null,
            } else null);
            // The active theme id rides /api/state on the 5 s feed cadence;
            // when the station flips its theme, refresh tokens right away.
            if (parsed.value.theme) |t| {
                if (t.active) |active| {
                    if (model.theme_override.len == 0 and !std.mem.eql(u8, active, model.theme_id)) {
                        fetchThemes(model, fx);
                    }
                }
            }
            // Private-station flags (#478) — booleans only, never the
            // password. Transitions only fire from .idle so a poll can't
            // restart an in-flight check or re-prompt over a typed password.
            const priv = parsed.value.privacy orelse json.Privacy{};
            model.privacy_private = priv.privatePlayer orelse false;
            model.privacy_listener_auth = priv.listenerAuth orelse false;
            syncStationGate(model, fx);
            // Timeline ledger: UP NEXT + PLAYED.
            if (parsed.value.upcoming) |list| {
                model.upcoming_count = 0;
                for (list) |e| {
                    if (model.upcoming_count >= max_upcoming) break;
                    const i = model.upcoming_count;
                    setStr(&model.up_title_store[i], &model.upcoming_rows[i].title, e.title orelse continue);
                    setStr(&model.up_artist_store[i], &model.upcoming_rows[i].artist, e.artist orelse "");
                    setStr(&model.up_req_store[i], &model.upcoming_rows[i].req_by, e.requestedBy orelse "");
                    model.upcoming_count += 1;
                }
            }
            if (parsed.value.history) |list| {
                model.history_count = 0;
                for (list) |e| {
                    if (model.history_count >= max_history) break;
                    const i = model.history_count;
                    setStr(&model.hist_title_store[i], &model.history_rows[i].title, e.title orelse continue);
                    setStr(&model.hist_artist_store[i], &model.history_rows[i].artist, e.artist orelse "");
                    model.history_rows[i].played_at_s = station_time.playedAt(e.startedAt, e.t, e.queuedAt);
                    model.history_count += 1;
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
            // Capture the theme catalogue (ids + names) for the fascia sheet.
            model.theme_count = 0;
            for (list) |t| {
                const id = t.id orelse continue;
                if (model.theme_count >= max_themes) break;
                setStr(&model.theme_ids_store[model.theme_count], &model.theme_ids[model.theme_count], id);
                setStr(&model.theme_names_store[model.theme_count], &model.theme_names[model.theme_count], t.name orelse "");
                setStr(&model.theme_descs_store[model.theme_count], &model.theme_descs[model.theme_count], t.description orelse "");
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
            // Exactly one terminal per load. A result for anything but the
            // current in-flight id is a late arrival the track already moved
            // past: release its pixels if it managed to register them, and
            // leave the art on screen alone.
            if (r.id != model.cover_loading_id) {
                if (r.outcome == .loaded) _ = fx.unregisterImage(r.id);
                return;
            }
            model.cover_loading_id = 0;
            // Every other outcome (404 on an unknown id, a dead network, a
            // decode the platform codec refused) keeps cover_id at 0, which
            // the stage already draws as the initials disc.
            if (r.outcome != .loaded) return;
            if (model.cover_id != 0) _ = fx.unregisterImage(model.cover_id);
            model.cover_id = r.id;
        },
        .got_persona => |r| {
            for (model.persona_loading[0..model.persona_roster.count], 0..) |id, i| {
                if (id == 0 or id != r.id) continue;
                model.persona_loading[i] = 0;
                if (r.outcome == .loaded) model.persona_images[i] = r.id;
                return;
            }
            if (r.outcome == .loaded) _ = fx.unregisterImage(r.id);
        },
        .got_session => |r| {
            const current_reply = model.listener_fetches.finish(r.key, model.listener_generation);
            if (!current_reply or r.key != model.listener_session_key) {
                if (model.listener_feed_deferred) fetchFeed(model, fx);
                return;
            }
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.Session, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const msgs = parsed.value.messages orelse return;
            model.raw_booth_count = 0;
            const start = msgs.len - @min(msgs.len, listener_time.max_session_turns);
            for (msgs[start..]) |message| {
                decodeBoothTurn(&model.raw_booth[model.raw_booth_count], message);
                model.raw_booth_count += 1;
            }
            refreshListener(model, fx, native_sdk.nowMs());
        },
        .got_schedule => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.SchedulePayload, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const shows = parsed.value.shows orelse return;
            const personas = parsed.value.personas orelse &[_]json.SchedPersona{};
            if (parsed.value.timezone) |v| setStr(&model.timezone_store, &model.timezone, v);
            if (parsed.value.locale) |v| model.station_locale = station_time.locale(v);
            dropPersonas(model, fx);
            model.persona_roster.apply(personas, parsed.value.soulsPublished orelse false);
            loadPersonas(model, fx);
            resetScheduleDisclosures(model);
            model.show_count = 0;
            for (shows) |s| {
                if (model.show_count >= max_shows) break;
                const i = model.show_count;
                const name = s.name orelse continue;
                model.show_rows[i] = .{};
                setStr(&model.show_ids_store[i], &model.show_rows[i].id, s.id orelse "");
                setStr(&model.show_names_store[i], &model.show_rows[i].name, name);
                setStr(&model.show_topics_store[i], &model.show_rows[i].topic, s.topic orelse "");
                var persona_name: []const u8 = "";
                if (s.personaId) |pid| {
                    if (model.persona_roster.find(pid)) |pi| {
                        persona_name = model.persona_roster.rows[pi].name;
                        model.show_rows[i].persona_slot = pi;
                    }
                }
                setStr(&model.show_personas_store[i], &model.show_rows[i].persona, persona_name);
                model.show_rows[i].guests = model.persona_roster.guests(&model.show_guests_store[i], s.guestPersonaIds orelse &.{});
                model.show_count += 1;
            }
            // Grid: showId per day/hour → show index (+1) in sched_grid.
            model.sched_grid = [_][24]u8{[_]u8{0} ** 24} ** 7;
            if (parsed.value.schedule) |grid| {
                for (0..7) |d| {
                    const col = grid.day(d) orelse continue;
                    for (col, 0..) |slot, h| {
                        if (h >= 24) break;
                        const sid = slot orelse continue;
                        // Resolve the show id against the catalogue we kept.
                        var idx: usize = 0;
                        var found = false;
                        for (model.show_rows[0..model.show_count], 0..) |s, si| {
                            if (std.mem.eql(u8, s.id, sid)) {
                                idx = si;
                                found = true;
                                break;
                            }
                        }
                        if (found) model.sched_grid[d][h] = @intCast(idx + 1);
                    }
                }
            }
        },
        .got_dj => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.DjPublic, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const p = parsed.value;
            if (p.station) |s| {
                if (s.len > 0) setStr(&model.station_name_buf, &model.station_name, s);
            } else if (p.name) |n| {
                if (n.len > 0) setStr(&model.station_name_buf, &model.station_name, n);
            }
            if (p.location) |l| setStr(&model.station_loc_buf, &model.station_loc, l);
            saveSettings(model, fx); // persist the resolved station name
        },
        .got_directory => |r| {
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse([]json.DirectoryStation, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            model.discover_count = 0;
            for (parsed.value) |st| {
                if (model.discover_count >= max_discover) break;
                const url = st.url orelse continue;
                if (url.len == 0) continue;
                // The tuned station needn't discover itself.
                if (std.mem.eql(u8, url, model.base)) continue;
                const i = model.discover_count;
                setStr(&model.discover_name_store[i], &model.discover_rows[i].name, st.name orelse url);
                setStr(&model.discover_url_store[i], &model.discover_rows[i].url, url);
                var sub: [64]u8 = undefined;
                var w: usize = 0;
                if (st.location) |loc| {
                    const n = @min(loc.len, 40);
                    @memcpy(sub[0..n], loc[0..n]);
                    w = n;
                }
                if (st.genre) |g| {
                    const sep = " · ";
                    if (g.len > 0 and w + sep.len + g.len <= sub.len) {
                        if (w > 0) {
                            @memcpy(sub[w..][0..sep.len], sep);
                            w += sep.len;
                        }
                        @memcpy(sub[w..][0..g.len], g);
                        w += g.len;
                    }
                }
                setStr(&model.discover_sub_store[i], &model.discover_rows[i].sub, sub[0..w]);
                model.discover_count += 1;
            }
            syncDirectoryStatus(model, fx, true);
        },
        .got_beacon => {}, // fire-and-forget
        .chrome_changed => |c| {
            model.chrome_top = c.top;
            model.chrome_leading = c.leading;
            model.chrome_trailing = c.trailing;
        },

        // ------------------------------------------------------ request slip
        .req_edit => |edit| model.req_buffer.apply(edit),
        .req_name_edit => |edit| model.req_name_buffer.apply(edit),
        .chip_pick => |text| {
            model.req_buffer.set(text);
            model.req_status = "";
        },
        .submit_req => {
            const text = model.req_buffer.text();
            if (text.len == 0) {
                model.req_status = "write the DJ a line first";
            } else {
                var esc_buf: [256]u8 = undefined;
                var name_esc_buf: [64]u8 = undefined;
                var body_buf: [420]u8 = undefined;
                const esc = jsonEscape(&esc_buf, text);
                const raw_name = std.mem.trim(u8, model.req_name_buffer.text(), " ");
                const name_esc = if (raw_name.len > 0) jsonEscape(&name_esc_buf, raw_name) else "Desktop";
                var req_url_buf: [256]u8 = undefined;
                const req_url = api.request(&req_url_buf, model.base) catch {
                    model.req_status = "bad station url";
                    return;
                };
                if (std.fmt.bufPrint(&body_buf, "{{\"text\":\"{s}\",\"name\":\"{s}\"}}", .{ esc, name_esc })) |body| {
                    cancelRequestReturn(model, fx);
                    model.req_return_allowed = model.active_tab == .request;
                    fx.fetch(.{
                        .key = keys.post_request,
                        .method = .POST,
                        .url = req_url,
                        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                        .body = body,
                        .on_response = Effects.responseMsg(.got_reqpost),
                    });
                    model.req_phase = .pending;
                    model.req_status = "";
                    model.req_ack = "";
                    model.req_track_title = "";
                    model.req_track_artist = "";
                    model.req_queue_pos = 0;
                } else |_| {
                    model.req_status = "request too long";
                }
            }
        },
        .got_reqpost => |r| {
            if (r.outcome != .ok) {
                model.req_phase = .failed;
                model.req_status = "request failed — try again";
                return;
            }
            if (r.status == 429) {
                model.req_phase = .failed;
                model.req_status = "slow down — try again shortly";
                return;
            }
            if (r.status != 202 and r.status != 200) {
                model.req_phase = .failed;
                model.req_status = "request not accepted";
                return;
            }
            const parsed = json.parse(json.RequestPost, std.heap.page_allocator, r.body) catch {
                model.req_phase = .done;
                scheduleRequestReturn(model, fx);
                return;
            };
            defer parsed.deinit();
            if (parsed.value.ack) |a| setStr(&model.req_ack_buf, &model.req_ack, a);
            if (parsed.value.requestId) |id| {
                setStr(&model.req_id_buf, &model.req_id, id);
                fx.startTimer(.{ .key = keys.request_poll, .interval_ms = 2000, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reqpoll) });
            } else {
                model.req_phase = .done;
                scheduleRequestReturn(model, fx);
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
            // A late status for a request the model already dropped (station
            // switch) must not resurrect the card.
            if (model.req_id.len == 0) return;
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.RequestStatus, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const st = parsed.value.status orelse "pending";
            if (parsed.value.ack) |a| setStr(&model.req_ack_buf, &model.req_ack, a);
            if (std.mem.eql(u8, st, "resolved")) {
                model.req_phase = .done;
                if (parsed.value.track) |tr| {
                    if (tr.title) |v| setStr(&model.req_track_title_buf, &model.req_track_title, v);
                    if (tr.artist) |v| setStr(&model.req_track_artist_buf, &model.req_track_artist, v);
                }
                if (parsed.value.queuePosition) |pos| model.req_queue_pos = pos;
                scheduleRequestReturn(model, fx);
            } else if (std.mem.eql(u8, st, "failed")) {
                model.req_phase = .failed;
                model.req_status = "couldn't find that one";
                if (parsed.value.message) |m| setStr(&model.req_ack_buf, &model.req_ack, m);
            } else {
                // Keep polling until terminal.
                fx.startTimer(.{ .key = keys.request_poll, .interval_ms = 2000, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_reqpoll) });
            }
        },
        .reset_request => {
            cancelRequestReturn(model, fx);
            model.req_phase = .idle;
            model.req_status = "";
            model.req_ack = "";
            model.req_track_title = "";
            model.req_track_artist = "";
            model.req_queue_pos = 0;
            model.req_id = "";
            model.req_buffer.clear();
        },
        .tick_request_return => |t| {
            if (t.outcome != .fired or !model.req_return_armed) return;
            cancelRequestReturn(model, fx);
            if (model.active_tab != .request or model.req_phase != .done) return;
            model.active_tab = .live;
            model.req_phase = .idle;
            model.req_status = "";
            model.req_ack = "";
            model.req_id = "";
            model.req_track_title = "";
            model.req_track_artist = "";
            model.req_queue_pos = 0;
            model.req_buffer.clear();
        },

        // --------------------------------------------------------- transport
        .audio_event => |e| {
            // Counted, never logged: this fires ~25 times a second. The
            // heartbeat reports the count once per 5s. See issue #23.
            model.hb_audio_events +|= 1;
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
                    if (!e.buffering) {
                        model.auth_recheck.reconnect_since = null;
                        fx.cancelTimer(keys.auth_recheck_timer);
                    } else armAuthRecheck(model, fx);
                    refreshTrackElapsed(model, native_sdk.nowMs());
                    refreshTrayStatus(model);
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
        .tune_toggle => {
            if (model.transport == .stopped) startStream(model, fx) else tuneOut(model, fx);
        },
        .tune_out => tuneOut(model, fx),
        .vol_up => {
            model.volume = @min(model.volume + 0.1, 1.0);
            // Nudging the volume implicitly unmutes.
            model.muted = false;
            fx.setAudioVolume(model.volume);
            scheduleSave(model, fx);
        },
        .vol_down => {
            model.volume = @max(model.volume - 0.1, 0.0);
            model.muted = false;
            fx.setAudioVolume(model.volume);
            scheduleSave(model, fx);
        },
        .volume_changed => {
            // The slider's applied value was mirrored into model.volume by
            // Options.sync before this dispatch; apply it to the output.
            model.muted = false;
            fx.setAudioVolume(model.volume);
            scheduleSave(model, fx);
        },
        .toggle_mute => {
            model.muted = !model.muted;
            fx.setAudioVolume(if (model.muted) 0.0 else model.volume);
        },
        .tick_save => |t| {
            if (t.outcome == .fired) saveSettings(model, fx);
        },
        .saved => {
            model.save_inflight = false;
            if (model.save_dirty) {
                model.save_dirty = false;
                saveSettings(model, fx);
            }
        },
        .discord_line => |line| {
            if (line.key != model.discord_spawn_key) return; // stale helper from before a respawn
            if (std.mem.eql(u8, line.line, "READY")) {
                model.discord_connected = true;
                model.discord_retry_count = 0;
                model.discord_error = "";
            } else if (std.mem.startsWith(u8, line.line, "ERROR: ")) {
                model.discord_error = mapDiscordError(line.line["ERROR: ".len..]);
            }
        },
        .discord_exited => |exit| {
            // Both filters are needed: the key check drops events from a
            // superseded helper whose natural exit was already in flight
            // when the respawn flipped keys (reason .exited, not
            // .cancelled) — without it, that stale exit would clear the
            // signature and the retry would kill the healthy new helper.
            if (exit.key != model.discord_spawn_key) return;
            if (exit.reason == .cancelled) return; // cancelled without respawn (disable / tune-out)
            model.discord_connected = false;
            model.discord_last_payload = ""; // forces the retry below to actually respawn
            if (!model.discord_enabled) return;
            scheduleDiscordRetry(model, fx);
        },
        .tick_discord_retry => |t| {
            if (t.outcome == .fired and model.discord_enabled) updateDiscordPresence(model, fx);
        },

        // -------------------------------------------------------- navigation
        .pick_tab => |tab| {
            cancelRequestReturn(model, fx);
            model.active_tab = tab;
            if (tab == .schedule) {
                model.day_picked = false;
                model.day_sel = model.stationDay();
                resetScheduleDisclosures(model);
            }
        },
        .open_timeline => {
            cancelRequestReturn(model, fx);
            model.active_tab = .timeline;
        },
        .open_booth => {
            cancelRequestReturn(model, fx);
            model.active_tab = .booth;
        },
        .close_panel => {
            cancelRequestReturn(model, fx);
            model.active_tab = .live;
        },
        .toggle_sidebar => {
            model.sidebar_open = !model.sidebar_open;
            if (model.sidebar_open) fetchDirectory(fx); // refresh Discover
        },
        .escape => {
            if (model.sheet != .none) {
                model.sheet = .none;
            } else if (model.sidebar_open) {
                model.sidebar_open = false;
            } else {
                cancelRequestReturn(model, fx);
                model.active_tab = .live;
            }
        },
        // Both writes are fire-and-forget: `writeClipboard` copies the text at
        // call time, so the stack scratch here is safe to let go, and a failed
        // write has no honest surface to report into (no toast in this UI).
        .copy_track => {
            // Same gate the markup uses, so the placeholder title can never
            // reach the clipboard even if the item is reached another way.
            if (!model.has_track()) return;
            var buf: [512]u8 = undefined;
            const text = if (model.artist.len == 0)
                std.fmt.bufPrint(&buf, "{s}", .{model.title}) catch return
            else
                std.fmt.bufPrint(&buf, "{s} — {s}", .{ model.title, model.artist }) catch return;
            fx.writeClipboard(.{ .key = keys.copy_clipboard, .text = text });
        },
        .copy_station => fx.writeClipboard(.{ .key = keys.copy_clipboard, .text = model.base }),
        .open_panel => model.sheet = .panel,
        .open_sleep => model.sheet = .sleep,
        .open_themes => model.sheet = .themes,
        .open_format => model.sheet = .format,
        .open_discord => model.sheet = .discord,
        .close_sheet => model.sheet = .none,
        // One player surface at a time: entering mini mode tucks the full
        // player into the Dock/taskbar (minimize is the only reversible
        // app-driven "get it off the glass" verb the SDK has — fx.closeWindow
        // is a real close and a closed shell window cannot come back), and
        // every path out of mini mode brings the full player back.
        .toggle_mini => {
            model.mini_open = !model.mini_open;
            if (model.mini_open) fx.minimizeWindow("main") else fx.showWindow("main");
        },
        .expand_mini, .mini_closed => {
            model.mini_open = false;
            fx.showWindow("main");
        },

        // --------------------------------------------------- tray window verbs
        // The player window closes to hidden on the macOS/Windows release
        // builds (close_policy "hide"; Linux and dev builds compile "quit" —
        // see app.zon), so the tray needs a real way back — and a real way
        // out. "Open player" asks for the full window, so it also leaves
        // mini mode rather than putting a second surface on the glass.
        .show_player => {
            model.mini_open = false;
            fx.showWindow("main");
        },
        .quit_app => fx.quitApp(),

        // ------------------------------------------------------- app lifecycle
        // Coming back to the app (from the tray, the Dock, cmd+tab) should show
        // the truth immediately rather than up to one poll interval of stale
        // track. The feed poll keeps running while we are away, so this is a
        // freshness nudge after the slower background cadence.
        .app_activated => {
            model.app_active = true;
            if (model.phase == .player and feedActive(model)) {
                fetchFeed(model, fx);
                fetchThemes(model, fx);
            } else if (model.phase == .player and model.transport != .stopped) {
                fetchTrack(model, fx);
            }
        },
        // Going away stops the FFT feed (the SDK gates it on the window being
        // visibly on screen), and that feed is also the visualizer's clock. Zero
        // the bars on the way out so returning never shows a frozen pattern from
        // whenever we were last on screen — they rise again from the first live
        // frame.
        .app_deactivated => {
            model.app_active = false;
            model.band_levels = [_]f32{0} ** spectrum.band_count;
        },
        .main_occlusion => |occluded| {
            model.main_occluded = occluded;
            if (!occluded and feedActive(model) and model.phase == .player) {
                fetchFeed(model, fx);
                fetchThemes(model, fx);
            }
        },

        // ------------------------------------------------------- sleep timer
        .sleep_pick => |min| {
            armSleep(model, fx, min);
            model.sheet = .panel; // back to the panel with the countdown showing
        },
        .sleep_cycle => {
            const order = [_]i64{ 0, 15, 30, 45, 60, 90 };
            var idx: usize = 0;
            for (order, 0..) |min, i| {
                if (model.sleep_minutes == min) idx = i;
            }
            const next = order[(idx + 1) % order.len];
            if (next == 0) disarmSleep(model, fx) else armSleep(model, fx, next);
        },
        .cancel_sleep => disarmSleep(model, fx),

        // --------------------------------------------------- booth / schedule
        .set_booth_filter => |f| model.booth_filter = f,
        .pick_day => |d| {
            model.day_sel = std.math.clamp(d, 0, 6);
            model.day_picked = true;
            resetScheduleDisclosures(model);
        },
        .toggle_slot_topic => |h| {
            if (h >= 0 and h < 24) model.slot_topic_open[@intCast(h)] = !model.slot_topic_open[@intCast(h)];
        },
        .toggle_slot_host => |h| {
            if (h >= 0 and h < 24) model.slot_host_open[@intCast(h)] = !model.slot_host_open[@intCast(h)];
        },
        .toggle_now_topic => model.now_topic_open = !model.now_topic_open,
        .toggle_now_host => model.now_host_open = !model.now_host_open,

        // ------------------------------------------------ private-station gate
        .pw_edit => |edit| {
            model.pw_buffer.apply(edit);
            model.auth_status = "";
        },
        .submit_pw => {
            if (model.auth_gate == .checking) return;
            const pw = std.mem.trim(u8, model.pw_buffer.text(), " \t\r\n");
            if (pw.len == 0) return;
            postStationAuth(model, fx, pw, false);
        },
        .got_station_auth => |r| {
            if (model.auth_gate != .checking or !model.credentials_ready) return;
            if (r.outcome == .ok and r.status == 200) {
                setStr(&model.station_pw_buf, &model.station_pw, model.auth_try);
                model.auth_gate = .ok;
                model.auth_status = "";
                model.pw_buffer.clear();
                model.keep_station_memory = true;
                saveSettings(model, fx);
                if (model.transport != .playing) {
                    model.retry = 0;
                    startStream(model, fx);
                }
                if (model.stream_failed or model.buffering) armAuthRecheck(model, fx);
                return;
            }
            const stale = model.auth_from_store;
            lockStation(model, fx);
            if (r.outcome == .ok and r.status == 401) {
                if (stale) {
                    model.station_pw = "";
                    saveSettings(model, fx);
                } else model.auth_status = "That password was not accepted.";
            } else {
                // Offline, rate-limited and 5xx responses do not prove rotation.
                model.auth_status = if (r.outcome == .ok and r.status == 429)
                    "Too many attempts. Wait a few minutes and try again."
                else
                    "Couldn't verify the password. Try again when the station is reachable.";
            }
        },
        .got_station_credentials => |r| {
            if (r.key != keys.station_credentials) return;
            if (r.operation == .get) {
                if (model.credentials_ready) return;
                model.credentials_ready = true;
                if (r.outcome == .ok or r.outcome == .miss) {
                    if (r.outcome == .ok) model.station_memory.mergeVault(r.bytes, std.heap.page_allocator) catch {
                        model.credentials_blocked = true;
                    };
                    if (!model.credentials_blocked) {
                        // Existing vault records win over legacy plaintext.
                        restoreStationSettings(model);
                        model.credentials_dirty = true;
                        saveSettings(model, fx);
                    }
                } else model.credentials_blocked = true;
                if (model.credentials_blocked) {
                    model.station_status = "Couldn't read secure storage. Unlock the system keyring and restart to restore saved passwords; other settings still save.";
                    if (model.save_dirty) saveSettings(model, fx);
                }
                if (model.auth_gate == .checking) model.auth_gate = .idle;
                syncStationGate(model, fx);
                // A password loaded after the initial anonymous stream must
                // reach Icecast only once its station check succeeds.
                if (model.station_locked() and model.transport != .stopped) {
                    fx.stopAudio();
                    fx.cancelTimer(keys.reconnect);
                    model.transport = .stopped;
                }
            } else if (r.operation == .set and model.credentials_saving) {
                model.credentials_saving = false;
                if (r.outcome == .ok) {
                    saveSettings(model, fx);
                } else {
                    model.credentials_blocked = true;
                    model.credentials_dirty = true;
                    model.station_status = "Couldn't save the station password securely, so it stays in the settings file for now. Unlock the system keyring and restart to move it.";
                    saveSettings(model, fx);
                }
            }
        },
        .tick_auth_recheck => |t| {
            if (t.outcome != .fired) return;
            const reconnecting = model.transport == .playing and model.auth_gate == .ok and
                model.privacy_listener_auth and
                model.station_pw.len > 0 and (model.stream_failed or model.buffering);
            if (!reconnecting) {
                model.auth_recheck.reconnect_since = null;
                fx.cancelTimer(keys.auth_recheck_timer);
                return;
            }
            if (!model.auth_recheck_inflight and model.auth_recheck.due(native_sdk.monotonicMs(), true)) {
                var b: [256]u8 = undefined;
                const url = api.stationAuth(&b, model.base) catch return;
                var w = std.Io.Writer.fixed(&model.auth_recheck_body_buf);
                std.json.Stringify.value(.{ .password = model.station_pw }, .{}, &w) catch return;
                model.auth_recheck_inflight = true;
                fx.fetch(.{ .key = keys.post_auth_recheck, .url = url, .method = .POST,
                    .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                    .body = w.buffered(), .timeout_ms = 10_000, .on_response = Effects.responseMsg(.got_auth_recheck) });
            }
        },
        .got_auth_recheck => |r| {
            if (!model.auth_recheck_inflight) return;
            model.auth_recheck_inflight = false;
            if (model.auth_gate != .ok or model.transport != .playing or
                !(model.stream_failed or model.buffering)) return;
            if (r.outcome == .ok and r.status == 401) {
                model.station_pw = "";
                saveSettings(model, fx);
                lockStation(model, fx);
            }
        },

        // ---------------------------------------------------------- stations
        .station_edit => |edit| {
            model.station_buffer.apply(edit);
            model.station_status = "";
        },
        .tune_station => {
            model.ob_from_sidebar = true;
            obStart(model, fx, model.station_buffer.text(), "");
        },
        .pick_recent, .pick_discover => |url| {
            var base_buf: [256]u8 = undefined;
            if (api.normalizeBase(&base_buf, url)) |normalized| {
                // Resolve the display name before any MRU buffers move.
                var name: []const u8 = normalized;
                var saved = false;
                for (model.recents[0..model.recents_count]) |rec| {
                    if (std.mem.eql(u8, rec.url, normalized)) {
                        name = rec.name;
                        saved = true;
                    }
                }
                for (model.discover_rows[0..model.discover_count]) |d| {
                    if (std.mem.eql(u8, d.url, url)) name = d.name;
                }
                // A saved recent was accepted when it was added; only a station
                // the listener hasn't tuned before gets the cleartext warning.
                if (!saved and station_access.needsHttpConsent(normalized)) {
                    model.ob_from_sidebar = model.phase == .player;
                    obStart(model, fx, normalized, name);
                    return;
                }
                rememberStationSettings(model);
                setStr(&model.station_name_buf, &model.station_name, name);
                setStr(&model.base_buf, &model.base, normalized);
                pushRecent(model, model.station_name, model.base);
                model.sidebar_open = false;
                retune(model, fx);
            } else |_| {}
        },
        .forget_recent => |url| {
            var buf: [256]u8 = undefined;
            const base = api.normalizeBase(&buf, url) catch return;
            if (forgetRecent(model, base)) {
                model.credentials_dirty = model.station_memory.forget(base) or model.credentials_dirty;
                // Forgetting the active recent keeps its live session, but
                // subsequent unrelated saves must not recreate its secrets.
                if (std.mem.eql(u8, base, model.base)) model.keep_station_memory = false;
                saveSettings(model, fx);
                syncDirectoryStatus(model, fx, true);
            }
        },
        .press_like => {
            // Guarded so the L key (and a stale heart) is a no-op when there
            // is nothing likeable, it's already liked, or a POST is in flight.
            if (!model.like_available or model.like_liked or model.like_pending) return;
            if (model.like_song.len == 0) return;
            var b: [256]u8 = undefined;
            const url = api.like(&b, model.base) catch return;
            // The client sends what it thinks is on air so a tap that lands
            // just after a track change cannot like the wrong song (409).
            var w = std.Io.Writer.fixed(&model.like_body_buf);
            var esc: [64]u8 = undefined;
            w.print("{{\"songId\":\"{s}\"}}", .{jsonEscape(&esc, model.like_song)}) catch return;
            model.like_pending = true;
            fx.fetch(.{
                .key = keys.post_like,
                .method = .POST,
                .url = url,
                .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                .body = w.buffered(),
                .on_response = Effects.responseMsg(.got_like_post),
            });
        },
        .got_like_status => |r| {
            const current_reply = model.listener_fetches.finish(r.key, model.listener_like_generation);
            if (!current_reply or r.key != model.listener_like_key) {
                if (model.listener_like_deferred and model.like_song.len > 0) fetchLikeStatus(model, fx);
                return;
            }
            if (r.outcome != .ok or r.status != 200) return;
            const parsed = json.parse(json.LikeStatus, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const st = parsed.value;
            if (st.enabled) |e| if (!e) {
                model.like_available = false;
                return;
            };
            const sid = st.songId orelse {
                // Nothing likeable on air (jingle, spoken segment).
                model.like_available = false;
                return;
            };
            // An answer about some other song is stale — the next now-playing
            // poll re-asks with the fresh id.
            if (model.like_song.len == 0 or !std.mem.eql(u8, sid, model.like_song)) return;
            model.like_available = true;
            model.like_liked = st.liked orelse false;
            model.like_count = likeCount(st.count);
        },
        .got_like_post => |r| {
            model.like_pending = false;
            if (r.outcome != .ok) return;
            if (r.status == 409) {
                // The audible song can lag the server during a hold. Keep
                // its heart and target; promotion will fetch the next status.
                return;
            }
            if (r.status != 200) return; // 429 / disabled: stay tappable
            const parsed = json.parse(json.LikeStatus, std.heap.page_allocator, r.body) catch return;
            defer parsed.deinit();
            const st = parsed.value;
            if (st.songId) |sid| {
                if (model.like_song.len > 0 and !std.mem.eql(u8, sid, model.like_song)) return;
            }
            model.like_liked = st.liked orelse true;
            model.like_count = likeCount(st.count);
        },
        .follow_station => {
            model.theme_override = "";
            fetchThemes(model, fx);
            saveSettings(model, fx);
        },
        .pick_theme => |id| {
            setStr(&model.theme_override_buf, &model.theme_override, id);
            fetchThemes(model, fx);
            saveSettings(model, fx);
        },
        .pick_format => |id| {
            const fmt = stream_format.fromId(id) orelse return;
            // The sheet lists mounts this station doesn't serve so it can say
            // so; pressing one is inert. Absorbing it here keeps the markup
            // free of a second, press-less row variant, and keeps a dead value
            // out of format_pref (where it would persist and then silently
            // resolve back to the floor).
            if (!stream_format.platformSupports(fmt) or !model.stationEnables(fmt)) return;
            const before = model.effectiveFormat();
            model.format_pref = fmt;
            saveSettings(model, fx);
            // Retune in place mid-listen; a stopped/paused player keeps the
            // pick for its next start.
            if (model.transport == .playing and model.effectiveFormat() != before)
                startStream(model, fx);
            model.sheet = .panel; // back to the panel with the new value showing
        },
        // Nothing to start or stop: the next track flip consults
        // shouldNotifyTrack and that is the whole feature.
        .toggle_notify => {
            model.notify_track = !model.notify_track;
            saveSettings(model, fx);
        },
        .toggle_discord => {
            model.discord_enabled = !model.discord_enabled;
            model.discord_error = ""; // a fresh attempt starts with a clean slate
            updateDiscordPresence(model, fx);
            saveSettings(model, fx);
        },
        .discord_id_edit => |edit| {
            model.discord_id_buffer.apply(edit);
            model.discord_id_status = ""; // typing clears the complaint
        },
        .submit_discord_id => {
            const raw = std.mem.trim(u8, model.discord_id_buffer.text(), " \t\r\n");
            if (raw.len == 0) return;
            if (!discord_rpc.isValidClientId(raw)) {
                model.discord_id_status = "That doesn't look like an application ID (17-20 digits)";
                return;
            }
            setStr(&model.discord_client_id_buf, &model.discord_client_id, raw);
            model.discord_id_buffer.clear();
            model.discord_id_status = "";
            model.discord_error = "";
            // Pasting an ID is an unambiguous "turn it on" — don't make the
            // listener find the toggle as a second step.
            model.discord_enabled = true;
            updateDiscordPresence(model, fx);
            saveSettings(model, fx);
        },
        .clear_discord_id => {
            model.discord_client_id = "";
            model.discord_id_status = "";
            model.discord_error = "";
            // Falls back to the build-time default if one exists; otherwise
            // discord_configured() goes false and the presence cancels.
            updateDiscordPresence(model, fx);
            saveSettings(model, fx);
        },

        // -------------------------------------------------------- onboarding
        .ob_pick_scheme => |https| model.ob_https = https,
        .ob_run_check => {
            const raw = std.mem.trim(u8, model.station_buffer.text(), " \t\r\n");
            if (raw.len == 0) return;
            var buf: [256]u8 = undefined;
            const url = if (!station_access.hasScheme(raw) and !model.ob_https)
                std.fmt.bufPrint(&buf, "http://{s}", .{raw}) catch return
            else raw;
            obStart(model, fx, url, "");
        },
        .ob_pick_known => |url| {
            // Resolve name from known/discover rows.
            var name: []const u8 = "";
            if (std.mem.eql(u8, url, api.default_base)) name = "SUB/WAVE";
            for (model.recents[0..model.recents_count]) |rec| {
                if (std.mem.eql(u8, rec.url, url)) name = rec.name;
            }
            for (model.discover_rows[0..model.discover_count]) |d| {
                if (std.mem.eql(u8, d.url, url)) name = d.name;
            }
            obStart(model, fx, url, name);
        },
        .tick_ob_step => |t| {
            if (t.outcome != .fired or !model.ob_checking) return;
            if (model.ob_steps[0] == .run) {
                // Step 1 done; step 2 is the real gate — probe /health.
                model.ob_steps[0] = .ok;
                model.ob_steps[1] = .run;
                fetchObHealth(model, fx, keys.fetch_ob_health);
            } else if (model.ob_steps[2] == .run) {
                // Step 3 is cosmetic (controller answered → mount assumed up);
                // step 4 resolves the station identity, best-effort.
                model.ob_steps[2] = .ok;
                model.ob_steps[3] = .run;
                var b: [256]u8 = undefined;
                if (api.dj(&b, model.ob_target_url)) |u| {
                    fx.fetch(.{ .key = keys.fetch_ob_dj, .url = u, .timeout_ms = 6000, .on_response = Effects.responseMsg(.got_ob_dj) });
                } else |_| {
                    model.ob_steps[3] = .ok;
                    model.ob_done = true;
                }
            }
        },
        .got_ob_health => |r| {
            if (!model.ob_checking or model.ob_steps[1] != .run) return;
            const expected_key = if (model.ob_tried_https and !std.mem.startsWith(u8, model.ob_target_url, "https://")) keys.fetch_ob_fallback else keys.fetch_ob_health;
            if (r.key != expected_key) return;
            const healthy = blk: {
                if (r.outcome != .ok or r.status != 200 or r.truncated) break :blk false;
                const parsed = json.parse(json.Health, std.heap.page_allocator, r.body) catch break :blk false;
                defer parsed.deinit();
                break :blk std.mem.eql(u8, parsed.value.status orelse "", "on-air");
            };
            if (healthy) {
                model.ob_steps[1] = .ok;
                model.ob_steps[2] = .run;
                model.ob_insecure = station_access.needsHttpConsent(model.ob_target_url);
                fx.startTimer(.{ .key = keys.ob_step_timer, .interval_ms = 400, .mode = .one_shot, .on_fire = Effects.timerMsg(.tick_ob_step) });
            } else if (model.ob_allow_fallback and !(r.outcome == .ok and (r.status == 401 or r.status == 407))) {
                // A login challenge must never be retried in cleartext.
                model.ob_allow_fallback = false;
                var buf: [256]u8 = undefined;
                const url = std.fmt.bufPrint(&buf, "http://{s}", .{model.ob_target_url[8..]}) catch return;
                if (std.mem.eql(u8, model.ob_target_name, model.ob_target_url))
                    setStr(&model.ob_target_name_buf, &model.ob_target_name, url);
                setStr(&model.ob_target_url_buf, &model.ob_target_url, url);
                fetchObHealth(model, fx, keys.fetch_ob_fallback);
            } else {
                model.ob_steps[1] = .fail;
                var note_buf: [768]u8 = undefined;
                setStr(&model.ob_diag_buf, &model.ob_diag, station_access.diagnostic(&note_buf, @tagName(r.outcome), r.status, model.ob_tried_https));
                // SDK 0.10.1 exposes only the closed outcome and HTTP status,
                // not the underlying host error. Show all available detail.
                model.ob_raw = std.fmt.bufPrint(&model.ob_raw_buf, "{s} (HTTP {d})", .{ @tagName(r.outcome), r.status }) catch "";
            }
        },
        .got_ob_dj => |r| {
            if (!model.ob_checking or model.ob_steps[3] != .run) return;
            // Best-effort: any response completes the check.
            model.ob_steps[3] = .ok;
            model.ob_done = true;
            if (r.outcome == .ok and r.status == 200) {
                const parsed = json.parse(json.DjPublic, std.heap.page_allocator, r.body) catch return;
                defer parsed.deinit();
                if (parsed.value.station) |s| {
                    if (s.len > 0) setStr(&model.ob_target_name_buf, &model.ob_target_name, s);
                } else if (parsed.value.name) |n| {
                    if (n.len > 0) setStr(&model.ob_target_name_buf, &model.ob_target_name, n);
                }
            }
        },
        .ob_back => {
            model.ob_checking = false;
            model.ob_done = false;
            model.ob_diag = "";
            model.ob_raw = "";
            model.ob_insecure = false;
            if (model.ob_from_sidebar) {
                model.phase = .player;
                model.ob_from_sidebar = false;
            }
            model.ob_steps = [_]StepState{.wait} ** 4;
            fx.cancel(keys.fetch_ob_health);
            fx.cancel(keys.fetch_ob_fallback);
            fx.cancel(keys.fetch_ob_dj);
            fx.cancelTimer(keys.ob_step_timer);
        },
        .ob_tune_in => {
            if (!model.ob_done or model.ob_insecure) return;
            finishOnboarding(model, fx);
        },
        .ob_continue_http => {
            if (!model.ob_done or !model.ob_insecure) return;
            finishOnboarding(model, fx);
        },
    }
    syncSecondTimer(model, fx);
}

pub fn initialModel() Model {
    return .{};
}

fn timerInterval(fx: *Effects, key: u64) ?u64 {
    for (0..fx.pendingTimerCount()) |i| {
        const timer = fx.pendingTimerAt(i).?;
        if (timer.key == key) return timer.interval_ms;
    }
    return null;
}

test "request resolves, holds for 2.8 seconds, and returns to LIVE with a fresh slip" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player, .active_tab = .request, .req_id = "request-1", .req_phase = .pending, .req_return_allowed = true };
    update(&m, .{ .got_reqstat = .{ .key = keys.fetch_reqstat, .status = 200, .body = "{\"status\":\"resolved\",\"track\":{\"title\":\"Jóga\"}}" } }, &fx);
    try std.testing.expectEqual(ReqPhase.done, m.req_phase);
    try std.testing.expectEqual(Tab.request, m.active_tab);
    try std.testing.expectEqual(@as(?u64, 2800), timerInterval(&fx, keys.request_return));
    update(&m, .{ .tick_request_return = .{ .key = keys.request_return, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try std.testing.expectEqual(Tab.live, m.active_tab);
    try std.testing.expectEqual(ReqPhase.idle, m.req_phase);
    try std.testing.expectEqualStrings("", m.req_id);
    try std.testing.expectEqualStrings("", m.req_track_title);
}

test "manual navigation cancels return even when resolving later or revisiting REQUEST" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player, .active_tab = .request, .req_id = "request-1", .req_return_allowed = true };
    update(&m, .{ .got_reqstat = .{ .key = keys.fetch_reqstat, .status = 200, .body = "{\"status\":\"resolved\"}" } }, &fx);
    update(&m, .{ .pick_tab = .timeline }, &fx);
    try std.testing.expect(timerInterval(&fx, keys.request_return) == null);
    update(&m, .{ .pick_tab = .request }, &fx);
    update(&m, .{ .tick_request_return = .{ .key = keys.request_return, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try std.testing.expectEqual(Tab.request, m.active_tab);
    update(&m, .{ .got_reqstat = .{ .key = keys.fetch_reqstat, .status = 200, .body = "{\"status\":\"resolved\"}" } }, &fx);
    try std.testing.expect(timerInterval(&fx, keys.request_return) == null);
}

test "successful immediate request schedules return, failed request stays open" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player, .active_tab = .request, .req_return_allowed = true };
    update(&m, .{ .got_reqpost = .{ .key = keys.post_request, .status = 200, .body = "{}" } }, &fx);
    try std.testing.expectEqual(@as(?u64, 2800), timerInterval(&fx, keys.request_return));
    update(&m, .reset_request, &fx);
    m.req_return_allowed = true;
    update(&m, .{ .got_reqpost = .{ .key = keys.post_request, .status = 429 } }, &fx);
    try std.testing.expect(timerInterval(&fx, keys.request_return) == null);
    try std.testing.expectEqual(Tab.request, m.active_tab);
}

test "background polling slows, stops when tuned out, and activates immediately" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    update(&m, .app_deactivated, &fx);
    try std.testing.expectEqual(@as(?u64, 10_000), timerInterval(&fx, keys.feed_timer));
    try std.testing.expectEqual(@as(?u64, 30_000), timerInterval(&fx, keys.background_feed_timer));
    try std.testing.expect(timerInterval(&fx, keys.theme_timer) == null);
    try std.testing.expect(timerInterval(&fx, keys.signal_timer) == null);
    // The fast background tick polls the joined track pair the listener hold
    // resolves from; only the session waits for the slow tick.
    update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try std.testing.expectEqual(@as(usize, 2), fx.pendingFetchCount());
    try std.testing.expectEqual(m.listener_np_key, fx.pendingFetchAt(0).?.key);
    try std.testing.expectEqual(m.listener_state_key, fx.pendingFetchAt(1).?.key);
    update(&m, .{ .tick_background_feed = .{ .key = keys.background_feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try std.testing.expectEqual(@as(usize, 3), fx.pendingFetchCount());
    update(&m, .tune_out, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    update(&m, .{ .tick_background_feed = .{ .key = keys.background_feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    while (fx.takeMsg()) |msg| update(&m, msg, &fx);
    update(&m, .app_activated, &fx);
    try std.testing.expectEqual(@as(usize, 4), fx.pendingFetchCount());
    try std.testing.expectEqual(@as(?u64, 5000), timerInterval(&fx, keys.feed_timer));
    try std.testing.expectEqual(@as(?u64, 30_000), timerInterval(&fx, keys.theme_timer));
    try std.testing.expect(timerInterval(&fx, keys.background_feed_timer) == null);
}

test "host occlusion and mini mode throttle even while the app keeps focus" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    update(&m, .{ .main_occlusion = true }, &fx);
    try std.testing.expectEqual(@as(?u64, 10_000), timerInterval(&fx, keys.feed_timer));
    update(&m, .toggle_mini, &fx);
    try std.testing.expectEqual(@as(?u64, 10_000), timerInterval(&fx, keys.feed_timer));
    m.main_occluded = false;
    update(&m, .expand_mini, &fx);
    try std.testing.expectEqual(@as(?u64, 5000), timerInterval(&fx, keys.feed_timer));
    update(&m, .app_deactivated, &fx);
    try std.testing.expectEqual(@as(?u64, 10_000), timerInterval(&fx, keys.feed_timer));
}

test "background theme flips and late health responses cannot restart paused polling" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player, .app_active = false, .probe_slow = true };
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .status = 200, .body = "{\"theme\":{\"active\":\"classic-dark\"}}" } }, &fx);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    update(&m, .{ .got_health = .{ .key = keys.fetch_health, .status = 200 } }, &fx);
    try std.testing.expect(timerInterval(&fx, keys.signal_timer) == null);
    try std.testing.expect(timerInterval(&fx, keys.theme_timer) == null);
}

test "directory probes only visible lists, labels live and offline, and cancels on close" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    m.recents[0] = .{ .name = "One", .url = "https://one.test" };
    m.recents_count = 1;
    m.discover_rows[0] = .{ .name = "Two", .url = "https://two.test" };
    m.discover_count = 1;
    update(&m, .toggle_sidebar, &fx);
    try std.testing.expectEqual(@as(?u64, 30_000), timerInterval(&fx, keys.directory_status_timer));
    try fx.feedResponse(keys.directory_status_base, 200, "{\"nowPlaying\":{\"artist\":\"Björk\",\"title\":\"Jóga\"}}");
    try fx.feedResponseOutcome(keys.directory_status_base + 1, .timed_out, 0, "");
    while (fx.takeMsg()) |msg| update(&m, msg, &fx);
    try std.testing.expectEqualStrings("on air · Björk — Jóga", m.directory_status.find("https://one.test").?.label());
    try std.testing.expectEqualStrings("offline", m.directory_status.find("https://two.test").?.label());
    update(&m, .{ .tick_directory_status = .{ .key = keys.directory_status_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    update(&m, .toggle_sidebar, &fx);
    try std.testing.expect(timerInterval(&fx, keys.directory_status_timer) == null);
    try std.testing.expect(!m.directory_status.enabled);
    while (fx.takeMsg()) |msg| update(&m, msg, &fx);
    for (m.directory_status.entries) |entry| try std.testing.expect(!entry.pending);
    update(&m, .{ .tick_directory_status = .{ .key = keys.directory_status_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    for (m.directory_status.entries) |entry| try std.testing.expect(!entry.pending);
}

test "onboarding check, mini player and station switch close directory polling" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    syncDirectoryStatus(&m, &fx, true);
    try std.testing.expect(m.directory_status.find(api.default_base) != null);
    update(&m, .{ .ob_pick_known = api.default_base }, &fx);
    try std.testing.expect(!m.directory_status.enabled);
    update(&m, .ob_back, &fx);
    try std.testing.expect(m.directory_status.enabled);
    m.phase = .player;
    m.sidebar_open = true;
    update(&m, .toggle_mini, &fx);
    try std.testing.expect(!m.directory_status.enabled);
    update(&m, .expand_mini, &fx);
    try std.testing.expect(m.directory_status.enabled);
    update(&m, .{ .pick_recent = "https://another.test" }, &fx);
    try std.testing.expect(!m.directory_status.enabled);
    try std.testing.expect(timerInterval(&fx, keys.directory_status_timer) == null);
}

test "reopening a list before cancellation settles immediately reprobes the row" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    m.recents[0] = .{ .name = "One", .url = "https://one.test" };
    m.recents_count = 1;
    update(&m, .toggle_sidebar, &fx);
    update(&m, .toggle_sidebar, &fx);
    update(&m, .toggle_sidebar, &fx);
    while (fx.takeMsg()) |msg| update(&m, msg, &fx);
    try std.testing.expect(m.directory_status.entries[0].pending);
    var found = false;
    for (0..fx.pendingFetchCount()) |i| {
        const req = fx.pendingFetchAt(i).?;
        if (req.key == keys.directory_status_base) {
            found = true;
            try std.testing.expectEqualStrings("https://one.test/api/now-playing", req.url);
        }
    }
    try std.testing.expect(found);
}

test "suggestion context is copied and disappears when absent" {
    var fx = Effects.init(std.testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .status = 200, .body = "{\"context\":{\"festival\":{\"name\":\"Diwali\"},\"time\":{\"show\":\"Night Shift\",\"vibe\":\"slow burn\"},\"weather\":{\"condition\":\"rain\"}}}" } }, &fx);
    try std.testing.expectEqualStrings("Diwali", m.ctx_festival);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 4), m.chips(arena.allocator()).len);
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .status = 200, .body = "{}" } }, &fx);
    try std.testing.expectEqualStrings("", m.ctx_festival);
    try std.testing.expectEqual(@as(usize, 1), m.chips(arena.allocator()).len);
}

// -------------------------------------------------------------- tests
const testing = std.testing;

test "a buffered live-edge track keeps the audible title cover and like target" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body =
        \\{"nowPlaying":{"title":"Audible song","artist":"Artist","subsonic_id":"old"},"stream":{"bufferSeconds":22}}
    } }, &fx);
    m.cover_id = 1000;
    m.like_available = true;
    m.like_liked = true;
    var body: [256]u8 = undefined;
    const next = try std.fmt.bufPrint(
        &body,
        "{{\"nowPlaying\":{{\"title\":\"Live-edge song\",\"artist\":\"Artist\",\"subsonic_id\":\"new\",\"timestamp\":{d}}},\"stream\":{{\"bufferSeconds\":22}}}}",
        .{@divTrunc(native_sdk.nowMs(), 1000)},
    );
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = next } }, &fx);
    try testing.expectEqualStrings("Audible song", m.title);
    try testing.expectEqualStrings("old", m.cover_sid);
    try testing.expectEqualStrings("old", m.like_song);
    try testing.expectEqual(@as(u64, 1000), m.cover_id);
    try testing.expect(m.like_liked);
}

test "elapsed_str rolls to h:mm:ss past the hour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.track_elapsed_ms = 754_000; // 12:34
    try testing.expectEqualStrings("12:34", m.elapsed_str(arena));
    m.track_elapsed_ms = 5_025_000; // 1:23:45
    try testing.expectEqualStrings("1:23:45", m.elapsed_str(arena));
    m.track_elapsed_ms = 9_000; // 0:09
    try testing.expectEqualStrings("0:09", m.elapsed_str(arena));
}

test "np_head counts into the current track, not the whole session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.elapsed_ms = 200_000; // raw session position: 3:20 into the stream

    // A track lands with no start timestamp — elapsed anchors to the change.
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Night Drive\",\"artist\":\"The Midnight\",\"duration\":137}}" } }, &fx);
    try testing.expectEqualStrings("NOW PLAYING — 0:00 / 2:17", m.np_head(arena));

    // The decoder position advances 10s → 0:10, and the tray line follows.
    update(&m, .{ .audio_event = .{ .key = keys.audio, .kind = .position, .position_ms = 210_000 } }, &fx);
    try testing.expectEqualStrings("NOW PLAYING — 0:10 / 2:17", m.np_head(arena));
    try testing.expect(std.mem.startsWith(u8, m.tray_status, "0:10 ·"));

    // A new track resets the counter even though the stream position climbs.
    update(&m, .{ .audio_event = .{ .key = keys.audio, .kind = .position, .position_ms = 215_000 } }, &fx);
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Neon\",\"artist\":\"Purple Sky\",\"duration\":240}}" } }, &fx);
    try testing.expectEqualStrings("NOW PLAYING — 0:00 / 4:00", m.np_head(arena));
}

test "a server track-start timestamp anchors elapsed to the broadcast position" {
    var m: Model = .{};
    m.track_started_at_s = 1_000;
    m.track_duration_s = 137;
    refreshTrackElapsed(&m, 1_101_000); // wall clock 101s after the start
    try testing.expectEqual(@as(i64, 101_000), m.track_elapsed_ms);
    refreshTrackElapsed(&m, 999_000); // clock skew before the start clamps to 0
    try testing.expectEqual(@as(i64, 0), m.track_elapsed_ms);
    refreshTrackElapsed(&m, 1_400_000); // running long pegs at the duration
    try testing.expectEqual(@as(i64, 137_000), m.track_elapsed_ms);
}

test "now-playing timestamp lands in the model as the track start" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Inspiring Chill\",\"artist\":\"Sergey Gulevich\",\"timestamp\":1785497431,\"duration\":137}}" } }, &fx);
    try testing.expectEqual(@as(i64, 1_785_497_431), m.track_started_at_s);
}

test "now-playing ignores numbers outside the display integer range" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Still alive\",\"duration\":1e300,\"bpm\":-1e300},\"context\":{\"weather\":{\"temp\":1e300}}}" } }, &fx);
    try testing.expectEqualStrings("Still alive", m.title);
    try testing.expectEqual(@as(i64, 0), m.track_duration_s);
    try testing.expectEqual(@as(i64, 0), m.track_bpm);
    try testing.expectEqual(@as(i64, -999), m.ctx_temp);
}

test "track elapsed tolerates extreme station timestamps and durations" {
    var m: Model = .{};
    m.track_started_at_s = std.math.maxInt(i64);
    refreshTrackElapsed(&m, 1_101_000);
    try testing.expectEqual(@as(i64, 0), m.track_elapsed_ms);
    m.track_started_at_s = 1000;
    m.track_duration_s = std.math.maxInt(i64);
    refreshTrackElapsed(&m, 1_101_000);
    try testing.expectEqual(@as(i64, 101_000), m.track_elapsed_ms);
}

test "display integers preserve normal values and reject nonfinite boundaries" {
    try testing.expectEqual(@as(i64, 137), displayInteger(137.75, 0));
    try testing.expectEqual(@as(i64, -12), displayInteger(-12, -999));
    try testing.expectEqual(std.math.minInt(i64), displayInteger(-0x1p63, 0));
    inline for (.{ 0x1p63, -0x1p64, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |value| {
        try testing.expectEqual(@as(i64, -999), displayInteger(value, -999));
    }
}

test "initials take the artist's first two letters, with a fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.artist = "the Midnight";
    try testing.expectEqualStrings("TH", m.initials(arena));
    m.artist = "";
    try testing.expectEqualStrings("SW", m.initials(arena));
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

test "tune_out clears the failure banner, not just the transport" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.stream_failed = true;
    m.buffering = true;
    m.retry = 3;
    update(&m, .tune_out, &fx);
    try testing.expectEqual(Transport.stopped, m.transport);
    try testing.expect(!m.stream_failed);
    try testing.expectEqualStrings("TUNED OUT", m.state_line());
    try testing.expectEqualStrings("tuned out", m.status_word());
}

test "mute preserves the intended volume; a volume nudge unmutes" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.volume = 0.6;
    update(&m, .toggle_mute, &fx);
    try testing.expect(m.muted);
    try testing.expectEqual(@as(f32, 0.6), m.volume); // intended volume preserved
    try testing.expectEqualStrings("Muted", m.vol_display(arena));
    try testing.expectEqualStrings("Unmute", m.mute_label());
    update(&m, .vol_up, &fx); // nudging the volume unmutes
    try testing.expect(!m.muted);
    try testing.expect(m.volume > 0.65);
    try testing.expectEqualStrings("70%", m.vol_display(arena));
}

test "the volume sync adopts a real drag but never clobbers a model-side nudge" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};

    // First observation has nothing to compare against: the widget wins.
    m.volume = 0.2;
    m.reconcileVolumeFromWidget(0.8);
    try testing.expectEqual(@as(f32, 0.8), m.volume);

    // A genuine drag moves the widget, so the sync adopts it.
    m.reconcileVolumeFromWidget(0.5);
    try testing.expectEqual(@as(f32, 0.5), m.volume);

    // Float noise on a replayed value is not a drag.
    m.reconcileVolumeFromWidget(0.5 + 1e-6);
    try testing.expectEqual(@as(f32, 0.5), m.volume);

    // THE REGRESSION: a model-side nudge, then a sync pass carrying the
    // slider's still-stale pre-nudge value. The nudge must survive - this is
    // exactly what used to revert and made keyboard volume do nothing.
    update(&m, .vol_up, &fx);
    try testing.expect(m.volume > 0.55);
    const nudged = m.volume;
    m.reconcileVolumeFromWidget(0.5); // stale: the build has not rendered yet
    try testing.expectEqual(nudged, m.volume);

    // Once the build pushes the moved value out, the widget catches up and
    // the sync settles on it rather than oscillating.
    m.reconcileVolumeFromWidget(nudged);
    try testing.expectEqual(nudged, m.volume);
}

test "the volume sync accumulates small slider movements in both directions" {
    var m: Model = .{};
    m.reconcileVolumeFromWidget(0.5);

    // Individual sub-pixel moves are below the noise threshold, but their
    // cumulative travel must still reach the model instead of being lost.
    for (1..101) |step| {
        const value = 0.5 + @as(f32, @floatFromInt(step)) * 0.0003;
        m.reconcileVolumeFromWidget(value);
        try testing.expectApproxEqAbs(value, m.volume, Model.volume_widget_epsilon);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.53), m.volume, 1e-6);

    for (1..101) |step| {
        const value = 0.53 - @as(f32, @floatFromInt(step)) * 0.0003;
        m.reconcileVolumeFromWidget(value);
        try testing.expectApproxEqAbs(value, m.volume, Model.volume_widget_epsilon);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.volume, 1e-6);
}

test "a nudge while muted survives the sync, so unmute restores the nudged level" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.volume = 0.4;
    m.reconcileVolumeFromWidget(0.4); // seed the observed value
    update(&m, .toggle_mute, &fx);
    try testing.expect(m.muted);

    update(&m, .vol_down, &fx); // nudging unmutes and lowers
    try testing.expect(!m.muted);
    const nudged = m.volume;
    try testing.expect(nudged < 0.35);

    // Stale sync must not restore the pre-nudge level behind toggle_mute's
    // back - otherwise a later unmute would push the wrong volume to output.
    m.reconcileVolumeFromWidget(0.4);
    try testing.expectEqual(nudged, m.volume);
}

test "tune_station reports an invalid address instead of failing silently" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // Empty buffer → normalizeBase errors → visible feedback, base unchanged.
    update(&m, .tune_station, &fx);
    try testing.expect(std.mem.indexOf(u8, m.station_status, "HTTP or HTTPS") != null);
    try testing.expectEqualStrings(api.default_base, m.base);
    // Editing the field clears the error as the listener fixes it.
    update(&m, .{ .station_edit = .{ .insert_text = "x" } }, &fx);
    try testing.expectEqualStrings("", m.station_status);
}

test "mini flow keeps one player surface: open minimizes main, every exit restores it" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // Entering mini mode tucks the full player away.
    update(&m, .toggle_mini, &fx);
    try testing.expect(m.mini_open);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().minimize_count);
    try testing.expectEqualStrings("main", fx.windowActionState().lastLabel());
    // EXPAND leaves mini mode and restores the full player.
    update(&m, .expand_mini, &fx);
    try testing.expect(!m.mini_open);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().show_count);
    try testing.expectEqualStrings("main", fx.windowActionState().lastLabel());
    // The user closing the mini window restores the full player too.
    update(&m, .toggle_mini, &fx);
    update(&m, .mini_closed, &fx);
    try testing.expect(!m.mini_open);
    try testing.expectEqual(@as(u32, 2), fx.windowActionState().show_count);
    // Tray "Close mini player" (toggle while open) is an exit as well.
    update(&m, .toggle_mini, &fx);
    update(&m, .toggle_mini, &fx);
    try testing.expect(!m.mini_open);
    try testing.expectEqual(@as(u32, 3), fx.windowActionState().show_count);
    // Tray "Open player" asks for the full window: mini mode ends with it.
    update(&m, .toggle_mini, &fx);
    update(&m, .show_player, &fx);
    try testing.expect(!m.mini_open);
    try testing.expectEqual(@as(u32, 4), fx.windowActionState().show_count);
    try testing.expectEqual(@as(u32, 4), fx.windowActionState().minimize_count);
    // The flow never really-closes a window (a closed shell window is gone
    // for good) and never quits the app.
    try testing.expectEqual(@as(u32, 0), fx.windowActionState().close_count);
    try testing.expectEqual(@as(u32, 0), fx.windowActionState().quit_count);
}

test "sleeve context menu copies the track and the station link" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};

    // Nothing on the deck yet: the copy is a no-op rather than a blank write.
    // (Markup hides the item behind has_track too; this is the model half.)
    update(&m, .copy_track, &fx);
    try testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());

    setStr(&m.title_buf, &m.title, "Overload");
    setStr(&m.artist_buf, &m.artist, "Tarsem Jassar");
    update(&m, .copy_track, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    try testing.expectEqualStrings("Overload — Tarsem Jassar", fx.pendingClipboardAt(0).?.text);

    // A track with no artist copies the bare title, not a dangling em dash.
    var fx2 = Effects.init(testing.allocator);
    defer fx2.deinit();
    fx2.executor = .fake;
    var m2: Model = .{};
    setStr(&m2.title_buf, &m2.title, "Untitled");
    update(&m2, .copy_track, &fx2);
    try testing.expectEqualStrings("Untitled", fx2.pendingClipboardAt(0).?.text);

    var fx3 = Effects.init(testing.allocator);
    defer fx3.deinit();
    fx3.executor = .fake;
    var m3: Model = .{};
    setStr(&m3.base_buf, &m3.base, "https://radio.example.com");
    update(&m3, .copy_station, &fx3);
    try testing.expectEqualStrings("https://radio.example.com", fx3.pendingClipboardAt(0).?.text);
}

test "jsonEscape escapes quotes and drops raw control bytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("say \\\"hi\\\"\\n", jsonEscape(&buf, "say \"hi\"\n"));
    try testing.expectEqualStrings("ab", jsonEscape(&buf, "a\x01b\r"));
}

test "escape closes sheet, then sidebar, then returns to LIVE" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.sheet = .sleep;
    m.sidebar_open = true;
    m.active_tab = .booth;
    update(&m, .escape, &fx);
    try testing.expectEqual(Sheet.none, m.sheet);
    try testing.expect(m.sidebar_open);
    update(&m, .escape, &fx);
    try testing.expect(!m.sidebar_open);
    try testing.expectEqual(Tab.booth, m.active_tab);
    update(&m, .escape, &fx);
    try testing.expectEqual(Tab.live, m.active_tab);
}

test "sleep timer arms a deadline and tune-outs on expiry" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    update(&m, .{ .sleep_pick = 15 }, &fx);
    try testing.expect(m.sleep_armed());
    try testing.expectEqual(@as(i64, 15), m.sleep_minutes);
    try testing.expectEqual(Sheet.panel, m.sheet);
    // Force the deadline into the past; the next second-tick tunes out.
    m.sleep_deadline_ms = 1;
    update(&m, .{ .tick_second = .{ .key = keys.second_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expect(!m.sleep_armed());
    try testing.expectEqual(Transport.stopped, m.transport);
}

test "pushRecent dedupes by url and keeps MRU order" {
    var m: Model = .{};
    pushRecent(&m, "One", "https://one.example");
    pushRecent(&m, "Two", "https://two.example");
    pushRecent(&m, "One again", "https://one.example");
    try testing.expectEqual(@as(usize, 2), m.recents_count);
    try testing.expectEqualStrings("One again", m.recents[0].name);
    try testing.expectEqualStrings("https://two.example", m.recents[1].url);
}

test "forgetRecent removes by url and closes the gap; unknown url is a no-op" {
    var m: Model = .{};
    pushRecent(&m, "One", "https://one.example");
    pushRecent(&m, "Two", "https://two.example");
    pushRecent(&m, "Three", "https://three.example");
    // MRU order is Three, Two, One. Forget the middle row.
    try testing.expect(forgetRecent(&m, "https://two.example"));
    try testing.expectEqual(@as(usize, 2), m.recents_count);
    try testing.expectEqualStrings("Three", m.recents[0].name);
    try testing.expectEqualStrings("One", m.recents[1].name);
    try testing.expectEqualStrings("https://one.example", m.recents[1].url);
    // Unknown url: nothing changes.
    try testing.expect(!forgetRecent(&m, "https://nope.example"));
    try testing.expectEqual(@as(usize, 2), m.recents_count);
    // Forget the last remaining rows down to empty.
    try testing.expect(forgetRecent(&m, "https://three.example"));
    try testing.expect(forgetRecent(&m, "https://one.example"));
    try testing.expectEqual(@as(usize, 0), m.recents_count);
    try testing.expect(!m.has_recents());
}

test "like flow: song change resets, status arms the heart, press likes once" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // A new song on air resets the state and asks the station for status.
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"T\",\"subsonic_id\":\"s1\"}}" } }, &fx);
    try testing.expectEqualStrings("s1", m.like_song);
    try testing.expect(!m.like_available);
    // Status for the current song arms the heart with the airing's count.
    update(&m, .{ .got_like_status = .{ .key = m.listener_like_key, .outcome = .ok, .status = 200, .body = "{\"enabled\":true,\"songId\":\"s1\",\"liked\":false,\"count\":2}" } }, &fx);
    try testing.expect(m.like_available);
    try testing.expect(!m.like_liked);
    try testing.expectEqual(@as(u32, 2), m.like_count);
    // A stale status (some other song) changes nothing.
    update(&m, .{ .got_like_status = .{ .key = m.listener_like_key, .outcome = .ok, .status = 200, .body = "{\"enabled\":true,\"songId\":\"sX\",\"liked\":true,\"count\":9}" } }, &fx);
    try testing.expectEqual(@as(u32, 2), m.like_count);
    // Press → pending; a second press is a no-op; the server confirm fills.
    update(&m, .press_like, &fx);
    try testing.expect(m.like_pending);
    update(&m, .press_like, &fx);
    update(&m, .{ .got_like_post = .{ .key = keys.post_like, .outcome = .ok, .status = 200, .body = "{\"ok\":true,\"songId\":\"s1\",\"liked\":true,\"count\":3}" } }, &fx);
    try testing.expect(m.like_liked);
    try testing.expect(!m.like_pending);
    try testing.expectEqual(@as(u32, 3), m.like_count);
    // Likes disabled station-side hides the heart entirely.
    update(&m, .{ .got_like_status = .{ .key = m.listener_like_key, .outcome = .ok, .status = 200, .body = "{\"enabled\":false}" } }, &fx);
    try testing.expect(!m.like_available);
}

test "day_slots compresses the grid into contiguous ranges" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    m.show_count = 1;
    m.show_rows[0] = .{ .name = "Night Static", .persona = "NOVA" };
    m.day_sel = 2;
    m.day_picked = true;
    // Hours 0-4 show 1; rest autopilot.
    for (0..5) |h| m.sched_grid[2][h] = 1;
    const slots = m.day_slots(arena);
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expectEqualStrings("00:00 – 05:00", slots[0].range);
    try testing.expectEqualStrings("Night Static", slots[0].show_name);
    try testing.expect(!slots[0].autopilot);
    try testing.expect(slots[1].autopilot);
}

test "onboarding walks entry → check → done and tunes in" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .onboarding;
    m.transport = .stopped;
    m.station_buffer.set("radio.example.com");
    update(&m, .ob_run_check, &fx);
    try testing.expect(m.ob_checking);
    try testing.expectEqualStrings("https://radio.example.com", m.ob_target_url);
    try testing.expectEqual(StepState.run, m.ob_steps[0]);
    // Step timer: host resolved → health probe fires.
    update(&m, .{ .tick_ob_step = .{ .key = keys.ob_step_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(StepState.ok, m.ob_steps[0]);
    try testing.expectEqual(StepState.run, m.ob_steps[1]);
    // Health ok → step 3 runs on the next step-timer fire.
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .outcome = .ok, .status = 200, .body = "{\"status\":\"on-air\"}" } }, &fx);
    try testing.expectEqual(StepState.ok, m.ob_steps[1]);
    update(&m, .{ .tick_ob_step = .{ .key = keys.ob_step_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(StepState.run, m.ob_steps[3]);
    // DJ answer (best-effort) completes the check.
    update(&m, .{ .got_ob_dj = .{ .key = keys.fetch_ob_dj, .outcome = .timed_out } }, &fx);
    try testing.expect(m.ob_done);
    update(&m, .ob_tune_in, &fx);
    try testing.expectEqual(Phase.player, m.phase);
    try testing.expectEqualStrings("https://radio.example.com", m.base);
    try testing.expectEqual(Transport.playing, m.transport);
    try testing.expectEqual(@as(usize, 1), m.recents_count);
}

test "request slip lifecycle: submit → pending → resolved card" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.req_buffer.set("play me something for late-night driving");
    m.req_name_buffer.set("Dana");
    update(&m, .submit_req, &fx);
    try testing.expectEqual(ReqPhase.pending, m.req_phase);
    update(&m, .{ .got_reqpost = .{ .key = keys.post_request, .outcome = .ok, .status = 202 } }, &fx);
    // Body was empty JSON-wise → parse fails → done without id. Reset works:
    update(&m, .reset_request, &fx);
    try testing.expectEqual(ReqPhase.idle, m.req_phase);
    try testing.expectEqualStrings("", m.req_text());
}

test "effective format: platform + station gates fall back to the MP3 floor" {
    var m: Model = .{};
    // Pre-first-poll the stored pick is trusted optimistically.
    m.format_pref = .aac;
    try testing.expectEqual(StreamFormat.aac, m.effectiveFormat());
    // Once flags land, an unadvertised mount snaps to the floor…
    m.stream_flags_known = true;
    try testing.expectEqual(StreamFormat.mp3, m.effectiveFormat());
    // …and comes back when the operator turns it on.
    m.stream_aac = true;
    try testing.expectEqual(StreamFormat.aac, m.effectiveFormat());
    // Ogg-encapsulated mounts additionally need a platform that demuxes Ogg.
    m.format_pref = .opus;
    m.stream_opus = true;
    const expect_opus: StreamFormat = if (stream_format.platformSupports(.opus)) .opus else .mp3;
    try testing.expectEqual(expect_opus, m.effectiveFormat());
}

test "format picker: every decodable mount is listed, a pick retunes in place" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    // The row count is a PLATFORM fact, not a station one: the sheet always
    // names everything this host can decode so a station down to the floor
    // reads as a fact rather than a missing feature. Station flags move the
    // `available` bits inside that fixed list.
    var decodable: usize = 0;
    for (StreamFormat.all) |f| {
        if (stream_format.platformSupports(f)) decodable += 1;
    }
    try testing.expectEqual(decodable, m.format_rows(arena).len);
    m.stream_flags_known = true;
    for (m.format_rows(arena)) |r| {
        try testing.expectEqual(std.mem.eql(u8, r.id, "mp3"), r.available);
        if (!r.available) try testing.expectEqualStrings("not served by this station", r.detail);
    }
    m.stream_aac = true;
    var available: usize = 0;
    for (m.format_rows(arena)) |r| {
        if (r.available) available += 1;
    }
    try testing.expectEqual(@as(usize, 2), available);
    // Picking AAC mid-listen rebuilds the stream URL on the new mount and
    // lands back on the panel.
    m.transport = .playing;
    m.sheet = .format;
    update(&m, .{ .pick_format = "aac" }, &fx);
    try testing.expectEqual(StreamFormat.aac, m.format_pref);
    try testing.expectEqualStrings("AAC", m.format_value(arena));
    try testing.expectEqual(Sheet.panel, m.sheet);
    try testing.expect(std.mem.startsWith(u8, &m.stream_url_buf, "https://www.getsubwave.com/stream.aac"));
    // Junk ids are ignored.
    update(&m, .{ .pick_format = "wav" }, &fx);
    try testing.expectEqual(StreamFormat.aac, m.format_pref);
}

test "format picker: pressing a mount the station doesn't serve is inert" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.stream_flags_known = true;
    m.stream_aac = true;
    m.format_pref = .aac;
    // FLAC is listed (on hosts that demux Ogg) purely to say it isn't served.
    // The press must not park a dead value in format_pref, where it would
    // persist to settings.json and then quietly resolve back to the floor.
    update(&m, .{ .pick_format = "flac" }, &fx);
    try testing.expectEqual(StreamFormat.aac, m.format_pref);
}

test "format chip: the bitrate only rides along on the station's own mount" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    // Nothing advertised yet → the bare label.
    try testing.expectEqualStrings("MP3", m.format_value(arena));
    m.stream_primary = .mp3;
    m.stream_bitrate = 192;
    try testing.expectEqualStrings("MP3 192k", m.format_value(arena));
    // Tuned to a different mount than the one that bitrate describes: the
    // number belongs to the station's primary mount and nothing measured this
    // one, so it must not be borrowed.
    m.stream_flags_known = true;
    m.stream_aac = true;
    m.format_pref = .aac;
    try testing.expectEqualStrings("AAC", m.format_value(arena));
}

test "got_np reads the primary mount's shape for the chip" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Model = .{};
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"stream\":{\"mount\":\"/stream.mp3\",\"format\":\"mp3\",\"bitrate\":192}}" } }, &fx);
    try testing.expectEqual(StreamFormat.mp3, m.stream_primary.?);
    try testing.expectEqualStrings("MP3 192k", m.format_value(arena));
    // A format id this build doesn't know leaves the pair unset rather than
    // pinning a bitrate to the wrong mount.
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"stream\":{\"format\":\"wav\",\"bitrate\":320}}" } }, &fx);
    try testing.expectEqual(@as(?StreamFormat, null), m.stream_primary);
    try testing.expectEqual(@as(u32, 0), m.stream_bitrate);
    try testing.expectEqualStrings("MP3", m.format_value(arena));
}

test "got_np stream flags retune a playing stream off a dead mount" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.format_pref = .aac;
    m.stream_flags_known = true;
    m.stream_aac = true;
    // Operator turns the AAC mount off — the next poll snaps to the floor.
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"stream\":{\"aacEnabled\":false}}" } }, &fx);
    try testing.expect(!m.stream_aac);
    try testing.expectEqual(StreamFormat.mp3, m.effectiveFormat());
    try testing.expect(std.mem.startsWith(u8, &m.stream_url_buf, "https://www.getsubwave.com/stream.mp3"));
}

test "settings round-trip the stream format; junk ids keep the floor" {
    var m: Model = .{};
    applySettingsJson(&m, "{\"streamFormat\":\"flac\",\"volume\":0.5}");
    try testing.expectEqual(StreamFormat.flac, m.format_pref);
    var m2: Model = .{};
    applySettingsJson(&m2, "{\"streamFormat\":\"wav\"}");
    try testing.expectEqual(StreamFormat.mp3, m2.format_pref);
}

test "private station: flags gate the player and a good password unlocks" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    m.transport = .playing;
    @memset(&m.stream_url_buf, 0); // deterministic bytes for the URL asserts
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = "{\"privacy\":{\"privatePlayer\":true,\"listenerAuth\":true}}" } }, &fx);
    try testing.expect(m.privacy_private);
    try testing.expect(m.privacy_listener_auth);
    try testing.expect(m.station_locked());
    try testing.expectEqual(AuthGate.prompt, m.auth_gate);
    // The gate tunes out (an unauthenticated stream would 401-loop) and
    // transport verbs are dead while it stands.
    try testing.expectEqual(Transport.stopped, m.transport);
    update(&m, .toggle_play, &fx);
    try testing.expectEqual(Transport.stopped, m.transport);
    // Type + submit → checking; 200 stores the password and tunes in with
    // the percent-encoded token riding the stream URL.
    m.pw_buffer.set("hunter 2");
    update(&m, .submit_pw, &fx);
    try testing.expectEqual(AuthGate.checking, m.auth_gate);
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .outcome = .ok, .status = 200 } }, &fx);
    try testing.expect(!m.station_locked());
    try testing.expectEqualStrings("hunter 2", m.station_pw);
    try testing.expectEqual(Transport.playing, m.transport);
    try testing.expect(std.mem.indexOf(u8, &m.stream_url_buf, "?auth=hunter%202") != null);
    try testing.expectEqualStrings("", m.pw_text());
}

test "private station: a rotated stored password re-prompts silently, a typed one shows the error" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    applySettingsJson(&m, "{\"stationPassword\":\"old-secret\"}");
    try testing.expectEqualStrings("old-secret", m.station_pw);
    // A lock appears → the stored password is re-validated, not prompted.
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = "{\"privacy\":{\"privatePlayer\":true}}" } }, &fx);
    try testing.expectEqual(AuthGate.checking, m.auth_gate);
    // 401 = rotation: forget it, prompt with no error to be wrong about.
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .outcome = .ok, .status = 401 } }, &fx);
    try testing.expectEqual(AuthGate.prompt, m.auth_gate);
    try testing.expectEqualStrings("", m.station_pw);
    try testing.expectEqualStrings("", m.auth_status);
    // A typed wrong password does get the error line (and 429 its own).
    m.pw_buffer.set("nope");
    update(&m, .submit_pw, &fx);
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .outcome = .ok, .status = 401 } }, &fx);
    try testing.expectEqualStrings("That password was not accepted.", m.auth_status);
    update(&m, .submit_pw, &fx);
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .outcome = .ok, .status = 429 } }, &fx);
    try testing.expect(std.mem.startsWith(u8, m.auth_status, "Too many attempts"));
    // Operator turns privacy off → the gate stands down on the next poll.
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = "{\"privacy\":{\"privatePlayer\":false}}" } }, &fx);
    try testing.expect(!m.station_locked());
    try testing.expectEqual(AuthGate.idle, m.auth_gate);
}

test "private station: switching stations never sends the old station's password" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    applySettingsJson(&m, "{\"stationPassword\":\"secret\"}");
    m.auth_gate = .ok;
    m.privacy_private = true;
    @memset(&m.stream_url_buf, 0); // deterministic bytes for the URL asserts
    update(&m, .{ .pick_recent = "https://other.example" }, &fx);
    try testing.expectEqualStrings("", m.station_pw);
    try testing.expectEqual(AuthGate.idle, m.auth_gate);
    try testing.expect(!m.privacy_private);
    // The new station's stream URL carries no stale ?auth= token.
    try testing.expect(std.mem.startsWith(u8, &m.stream_url_buf, "https://other.example/stream.mp3"));
    try testing.expect(!std.mem.startsWith(u8, &m.stream_url_buf, "https://other.example/stream.mp3?"));
}

test "station preferences migrate to normalized bases and newer map entries win" {
    var m: Model = .{};
    applySettingsJson(&m,
        \\{"station":"HTTPS://Radio.Example:443/","streamFormat":"opus","stationPassword":"legacy","recents":[{"url":"https://Second.Example/"}],"stationSettings":{"https://radio.example":{"streamFormat":"flac","stationPassword":"newer"},"https://second.example":{"streamFormat":"aac"},"https://unretained.example":{"stationPassword":"discard"}}}
    );
    try testing.expectEqualStrings("https://radio.example", m.base);
    try testing.expectEqual(StreamFormat.flac, m.format_pref);
    try testing.expectEqualStrings("newer", m.station_pw);
    try testing.expectEqual(@as(usize, 2), m.station_memory.count);
    try testing.expectEqual(StreamFormat.aac, m.station_memory.get("https://second.example").?.format);
}

test "station switch restores format and silently revalidates that station's password" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    applySettingsJson(&m, "{\"station\":\"https://first.example\",\"streamFormat\":\"opus\",\"stationPassword\":\"first-secret\"}");
    pushRecent(&m, "First", m.base);
    update(&m, .{ .pick_recent = "https://second.example" }, &fx);
    try testing.expectEqualStrings("", m.station_pw);
    m.format_pref = .flac;
    setStr(&m.station_pw_buf, &m.station_pw, "second-secret");
    update(&m, .{ .pick_recent = "https://first.example/" }, &fx);
    try testing.expectEqual(StreamFormat.opus, m.format_pref);
    try testing.expectEqualStrings("first-secret", m.station_pw);
    update(&m, .{ .got_state = .{ .key = m.listener_state_key, .status = 200, .body = "{\"privacy\":{\"listenerAuth\":true}}" } }, &fx);
    try testing.expectEqual(AuthGate.checking, m.auth_gate);
    try testing.expect(m.auth_from_store);
    try testing.expectEqualStrings("first-secret", m.auth_try);
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .status = 200 } }, &fx);
    update(&m, .{ .pick_recent = "https://second.example" }, &fx);
    try testing.expectEqual(StreamFormat.flac, m.format_pref);
    try testing.expectEqualStrings("second-secret", m.station_pw);
}

test "forgetting an active recent removes saved preferences without stopping its session" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    applySettingsJson(&m, "{\"station\":\"https://first.example\",\"streamFormat\":\"opus\",\"stationPassword\":\"secret\"}");
    pushRecent(&m, "First", m.base);
    update(&m, .{ .forget_recent = "https://first.example/" }, &fx);
    try testing.expectEqualStrings("secret", m.station_pw);
    try testing.expectEqual(Transport.playing, m.transport);
    try testing.expect(m.station_memory.get(m.base) == null);
    update(&m, .toggle_notify, &fx);
    try testing.expect(m.station_memory.get(m.base) == null);
    update(&m, .{ .pick_recent = "https://second.example" }, &fx);
    update(&m, .{ .pick_recent = "https://first.example" }, &fx);
    try testing.expectEqual(StreamFormat.mp3, m.format_pref);
    try testing.expectEqualStrings("", m.station_pw);
}

test "settings and vault round-trip nine stations at their bounds without leaking passwords" {
    var m: Model = .{};
    m.use_secure_credentials = true;
    var base_buf: [256]u8 = undefined;
    const long_name = [_]u8{1} ** 48;
    const secret = [_]u8{'"'} ** 128;
    for (0..max_recents + 1) |i| {
        const prefix = try std.fmt.bufPrint(&base_buf, "https://station{d}.example/", .{i});
        @memset(base_buf[prefix.len..station_access.max_base_bytes], 'a');
        const base = base_buf[0..station_access.max_base_bytes];
        _ = try m.station_memory.put(base, .opus, &secret);
        if (i < max_recents) pushRecent(&m, &long_name, base) else setStr(&m.base_buf, &m.base, base);
    }
    const bytes = try settingsSnapshot(&m);
    try testing.expect(bytes.len <= station_access.settings_bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "stationPassword") == null);
    var vault_buf: [station_access.vault_bytes]u8 = undefined;
    const vault = try m.station_memory.vaultSnapshot(&vault_buf);
    try testing.expect(vault.len <= native_sdk.platform.max_credential_secret_bytes);
    var restored: Model = .{};
    applySettingsJson(&restored, bytes);
    try restored.station_memory.mergeVault(vault, testing.allocator);
    restoreStationSettings(&restored);
    try testing.expectEqual(@as(usize, 9), restored.station_memory.count);
    try testing.expectEqual(StreamFormat.opus, restored.format_pref);
    try testing.expectEqualStrings(&secret, restored.station_pw);
}

test "vault migration commits secrets before scrubbing settings and preserves legacy on failure" {
    const services: native_sdk.platform.PlatformServices = .{};
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindCredentialsStore(.{ .services = &services, .service = "dev.subwave.test", .permitted = true });
    var m: Model = .{};
    m.use_secure_credentials = true;
    m.settings_path = "/tmp/station-access-test-settings.json";
    applySettingsJson(&m, "{\"stationPassword\":\"migration-secret\",\"streamFormat\":\"opus\"}");
    m.credentials_ready = false;
    update(&m, .{ .got_station_credentials = .{ .key = keys.station_credentials, .operation = .get, .outcome = .miss } }, &fx);
    try testing.expect(m.credentials_saving);
    try testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    const request = fx.pendingHostAt(0).?;
    try testing.expectEqualStrings("core.credentials.set", request.name);
    fx.cancel(keys.station_credentials);
    update(&m, .{ .got_station_credentials = .{ .key = keys.station_credentials, .operation = .set, .outcome = .ok } }, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(0).?.bytes, "migration-secret") == null);
    try testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(0).?.bytes, "stationPassword") == null);

    var failed: Model = .{};
    failed.use_secure_credentials = true;
    failed.settings_path = m.settings_path;
    applySettingsJson(&failed, "{\"stationPassword\":\"retain-secret\"}");
    failed.credentials_ready = false;
    // Both models share one channel; clear the first save's key.
    fx.cancel(keys.save_settings);
    const before = fx.pendingFileCount();
    update(&failed, .{ .got_station_credentials = .{ .key = keys.station_credentials, .operation = .get, .outcome = .locked } }, &fx);
    update(&failed, .toggle_notify, &fx);
    try testing.expect(failed.credentials_blocked);
    try testing.expectEqualStrings("retain-secret", failed.station_pw);
    // An unreadable vault no longer stalls settings: the save goes through and
    // keeps the legacy secret in the file instead of scrubbing it.
    try testing.expectEqual(before + 1, fx.pendingFileCount());
    try testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(before).?.bytes, "retain-secret") != null);
}

test "Linux fallback avoids the crashing SDK credential calls and round-trips station passwords" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.use_secure_credentials = false;
    m.settings_path = "/tmp/station-access-test-settings.json";
    applySettingsJson(&m, "{\"stationPassword\":\"linux-session-secret\",\"streamFormat\":\"opus\"}");
    boot(&m, &fx);
    try testing.expectEqual(@as(usize, 0), fx.pendingHostCount());
    const bytes = fx.pendingFileAt(0).?.bytes;
    var restored: Model = .{};
    applySettingsJson(&restored, bytes);
    try testing.expectEqualStrings("linux-session-secret", restored.station_pw);
    try testing.expectEqual(StreamFormat.opus, restored.format_pref);
    const parsed = try json.parse(json.Settings, testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expect(parsed.value.stationPassword == null);
    try testing.expectEqualStrings("linux-session-secret", parsed.value.stationSettings.?.map.get(m.base).?.stationPassword.?);
}

test "plaintext fallback fits the read limit even with maximally escaped passwords and names" {
    var m: Model = .{};
    m.use_secure_credentials = false;
    var base_buf: [256]u8 = undefined;
    const name = [_]u8{1} ** 48;
    const password = [_]u8{1} ** 128;
    for (0..max_recents + 1) |i| {
        const prefix = try std.fmt.bufPrint(&base_buf, "https://station{d}.example/", .{i});
        @memset(base_buf[prefix.len..station_access.max_base_bytes], '"');
        const base = base_buf[0..station_access.max_base_bytes];
        _ = try m.station_memory.put(base, .opus, &password);
        if (i < max_recents) pushRecent(&m, &name, base) else setStr(&m.base_buf, &m.base, base);
    }
    const bytes = try settingsSnapshot(&m);
    try testing.expect(bytes.len > 8192);
    try testing.expect(bytes.len <= station_access.settings_bytes);
    var restored: Model = .{};
    applySettingsJson(&restored, bytes);
    try testing.expectEqual(@as(usize, 9), restored.station_memory.count);
    try testing.expectEqualStrings(&password, restored.station_pw);
}

test "MRU eviction prunes both format and password and an override restores only its own station" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    var buf: [64]u8 = undefined;
    for (0..12) |i| {
        const url = try std.fmt.bufPrint(&buf, "https://station{d}.example", .{i});
        update(&m, .{ .pick_recent = url }, &fx);
        m.format_pref = .opus;
        setStr(&m.station_pw_buf, &m.station_pw, "its-secret");
        saveSettings(&m, &fx);
        try testing.expect(m.station_memory.count <= max_recents + 1);
    }
    try testing.expect(m.station_memory.get("https://station0.example") == null);
    setStr(&m.base_buf, &m.base, "https://override.example");
    restoreStationSettings(&m);
    try testing.expectEqualStrings("", m.station_pw);
    try testing.expectEqual(StreamFormat.mp3, m.format_pref);
    setStr(&m.base_buf, &m.base, "https://station11.example");
    restoreStationSettings(&m);
    try testing.expectEqualStrings("its-secret", m.station_pw);
    try testing.expectEqual(StreamFormat.opus, m.format_pref);
}

test "vault saves coalesce later password changes and failures never write plaintext" {
    const services: native_sdk.platform.PlatformServices = .{};
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindCredentialsStore(.{ .services = &services, .service = "dev.subwave.test", .permitted = true });
    var m: Model = .{};
    m.use_secure_credentials = true;
    m.settings_path = "/tmp/station-access-test-settings.json";
    setStr(&m.station_pw_buf, &m.station_pw, "first-secret");
    saveSettings(&m, &fx);
    setStr(&m.station_pw_buf, &m.station_pw, "last-secret");
    saveSettings(&m, &fx);
    try testing.expect(m.credentials_dirty);
    fx.cancel(keys.station_credentials);
    update(&m, .{ .got_station_credentials = .{ .key = keys.station_credentials, .operation = .set, .outcome = .ok } }, &fx);
    try testing.expect(m.credentials_saving);
    try testing.expectEqual(@as(usize, 0), fx.pendingFileCount());
    fx.cancel(keys.station_credentials);
    update(&m, .{ .got_station_credentials = .{ .key = keys.station_credentials, .operation = .set, .outcome = .locked } }, &fx);
    try testing.expect(m.credentials_blocked);
    try testing.expectEqualStrings("last-secret", m.station_pw);
    // The failed vault write falls back to the settings file, so the newest
    // password survives a restart.
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    try testing.expect(std.mem.indexOf(u8, fx.pendingFileAt(0).?.bytes, "last-secret") != null);
}

test "stored-password network failures do not erase credentials" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    applySettingsJson(&m, "{\"stationPassword\":\"keep-secret\"}");
    m.privacy_private = true;
    postStationAuth(&m, &fx, m.station_pw, true);
    update(&m, .{ .got_station_auth = .{ .key = keys.post_station_auth, .outcome = .timed_out } }, &fx);
    try testing.expectEqualStrings("keep-secret", m.station_pw);
    try testing.expectEqual(AuthGate.prompt, m.auth_gate);
}

test "reconnect rotation stops audio, clears only its station secret and ignores unavailable verdicts" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    applySettingsJson(&m, "{\"stationPassword\":\"old-secret\"}");
    m.privacy_listener_auth = true;
    m.auth_gate = .ok;
    m.stream_failed = true;
    m.auth_recheck_inflight = true;
    update(&m, .{ .got_auth_recheck = .{ .key = keys.post_auth_recheck, .outcome = .timed_out } }, &fx);
    try testing.expectEqual(AuthGate.ok, m.auth_gate);
    try testing.expectEqualStrings("old-secret", m.station_pw);
    m.auth_recheck_inflight = true;
    update(&m, .{ .got_auth_recheck = .{ .key = keys.post_auth_recheck, .status = 401 } }, &fx);
    try testing.expectEqual(AuthGate.prompt, m.auth_gate);
    try testing.expectEqual(Transport.stopped, m.transport);
    try testing.expectEqualStrings("", m.station_pw);
    try testing.expectEqualStrings("", m.station_memory.get(m.base).?.password());
}

test "reconnect timer posts its saved password only after the threshold and recovery disarms it" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    applySettingsJson(&m, "{\"stationPassword\":\"saved-secret\"}");
    m.privacy_listener_auth = true;
    m.auth_gate = .ok;
    scheduleReconnect(&m, &fx);
    update(&m, .{ .tick_auth_recheck = .{ .key = keys.auth_recheck_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expect(!m.auth_recheck_inflight);
    m.auth_recheck.reconnect_since = native_sdk.monotonicMs() -| 15_000;
    update(&m, .{ .tick_auth_recheck = .{ .key = keys.auth_recheck_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expect(m.auth_recheck_inflight);
    const request = fx.pendingFetchAt(0).?;
    try testing.expectEqual(keys.post_auth_recheck, request.key);
    try testing.expectEqualStrings("{\"password\":\"saved-secret\"}", request.body);
    update(&m, .{ .audio_event = .{ .key = keys.audio, .kind = .position, .buffering = false } }, &fx);
    update(&m, .{ .got_auth_recheck = .{ .key = keys.post_auth_recheck, .status = 401 } }, &fx);
    try testing.expectEqual(AuthGate.ok, m.auth_gate);
    try testing.expect(m.auth_recheck.reconnect_since == null);
}

test "bare-host checks fall back to HTTP and require explicit public cleartext consent" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.station_buffer.set("radio.example");
    update(&m, .ob_run_check, &fx);
    m.ob_steps = .{ .ok, .run, .wait, .wait };
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .outcome = .tls_failed } }, &fx);
    try testing.expectEqualStrings("http://radio.example", m.ob_target_url);
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_fallback, .status = 200, .body = "{\"status\":\"on-air\"}" } }, &fx);
    try testing.expect(m.ob_insecure);
    m.ob_done = true;
    update(&m, .ob_tune_in, &fx);
    try testing.expectEqual(Phase.onboarding, m.phase);
    update(&m, .ob_continue_http, &fx);
    try testing.expectEqual(Phase.player, m.phase);
    try testing.expectEqualStrings("http://radio.example", m.base);
}

test "sidebar uses the same health check, preserves the player on cancel and exempts LAN HTTP" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    m.format_pref = .opus;
    m.station_buffer.set("http://BOX.local:7701/");
    update(&m, .tune_station, &fx);
    try testing.expectEqual(Phase.onboarding, m.phase);
    try testing.expectEqualStrings(api.default_base, m.base);
    update(&m, .ob_back, &fx);
    try testing.expectEqual(Phase.player, m.phase);
    try testing.expectEqual(StreamFormat.opus, m.format_pref);
    update(&m, .tune_station, &fx);
    m.ob_steps = .{ .ok, .run, .wait, .wait };
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .status = 200, .body = "{\"status\":\"on-air\"}" } }, &fx);
    try testing.expect(!m.ob_insecure);
    m.ob_done = true;
    update(&m, .ob_tune_in, &fx);
    try testing.expectEqualStrings("http://box.local:7701", m.base);
}

test "login challenges never downgrade, explicit HTTPS never falls back and HTML health fails" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    obStart(&m, &fx, "radio.example", "");
    m.ob_steps = .{ .ok, .run, .wait, .wait };
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .status = 401 } }, &fx);
    try testing.expectEqual(StepState.fail, m.ob_steps[1]);
    try testing.expectEqualStrings("https://radio.example", m.ob_target_url);
    try testing.expect(std.mem.indexOf(u8, m.ob_diag, "not supported") != null);
    obStart(&m, &fx, "https://radio.example", "");
    m.ob_steps = .{ .ok, .run, .wait, .wait };
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .status = 200, .body = "<html>login</html>" } }, &fx);
    try testing.expectEqual(StepState.fail, m.ob_steps[1]);
    try testing.expect(std.mem.indexOf(u8, m.ob_diag, "port 7701") != null);
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .outcome = .tls_failed } }, &fx);
    try testing.expectEqualStrings("https://radio.example", m.ob_target_url);
}

test "public HTTP recent and directory selections also require consent" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    update(&m, .{ .pick_discover = "http://radio.example" }, &fx);
    try testing.expectEqualStrings(api.default_base, m.base);
    try testing.expectEqual(Phase.onboarding, m.phase);
    m.ob_steps = .{ .ok, .run, .wait, .wait };
    update(&m, .{ .got_ob_health = .{ .key = keys.fetch_ob_health, .status = 200, .body = "{\"status\":\"on-air\"}" } }, &fx);
    m.ob_done = true;
    update(&m, .ob_tune_in, &fx);
    try testing.expectEqualStrings(api.default_base, m.base);
    update(&m, .ob_continue_http, &fx);
    try testing.expectEqualStrings("http://radio.example", m.base);
}

// Configure Discord the way a listener would end up configured: a stored,
// validated client ID (the discord.zon build default is "" in this repo).
fn testSetDiscordId(m: *Model) void {
    setStr(&m.discord_client_id_buf, &m.discord_client_id, "123456789012345678");
}

test "shouldNotifyTrack gates on opt-in, background, on-air and a real track" {
    var m: Model = .{};
    setStr(&m.title_buf, &m.title, "Night Drive");
    m.transport = .playing;
    m.stream_online = true;
    m.notify_track = true;
    m.app_active = false;

    // All four gates open.
    try testing.expect(m.shouldNotifyTrack());

    // Opt-out wins over everything else.
    m.notify_track = false;
    try testing.expect(!m.shouldNotifyTrack());
    m.notify_track = true;

    // Foreground: the LIVE stage already names the track, so a toast would
    // just repeat what is on screen.
    m.app_active = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.app_active = false;

    // Tuned out: this is a player, not a station ticker.
    m.transport = .stopped;
    try testing.expect(!m.shouldNotifyTrack());
    m.transport = .playing;

    // Mid-buffer and mid-failure are not "on air".
    m.buffering = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.buffering = false;
    m.stream_failed = true;
    try testing.expect(!m.shouldNotifyTrack());
    m.stream_failed = false;

    // Stream offline: nothing is airing to announce.
    m.stream_online = false;
    try testing.expect(!m.shouldNotifyTrack());
    m.stream_online = true;

    // The first fill: got_np sets track_changed when the title flips from ""
    // on the very first fetch, but that is a first fill at launch, not a
    // track change, and must not fire a toast.
    m.title = "";
    try testing.expect(!m.shouldNotifyTrack());
}

test "trackNotification carries a stable id and the Open Player action" {
    var m: Model = .{};
    setStr(&m.title_buf, &m.title, "Night Drive");
    setStr(&m.artist_buf, &m.artist, "The Midnight");
    setStr(&m.show_buf, &m.show, "graveyard shift");

    const n = m.trackNotification();
    try testing.expectEqualStrings("now-playing", n.id);
    try testing.expectEqualStrings("Night Drive", n.title);
    try testing.expectEqualStrings("The Midnight", n.subtitle);
    try testing.expectEqualStrings("graveyard shift", n.body);
    try testing.expectEqualStrings("Open Player", n.action_label);
    try testing.expectEqualStrings("open-player", n.action_command);

    // The id is what makes the replacement work: two consecutive tracks must
    // reuse it, or the second toast stacks under the first instead of
    // taking its place.
    setStr(&m.title_buf, &m.title, "Static Bloom");
    try testing.expectEqualStrings(n.id, m.trackNotification().id);

    // The SDK drops a notification whose action fields are half-set, and it
    // does so silently — no toast at all, rather than a display-only one.
    const half_set = (n.action_label.len == 0) != (n.action_command.len == 0);
    try testing.expect(!half_set);

    // A show-less track still notifies; only the body goes empty. The
    // action and the id do not depend on the optional fields.
    m.show = "";
    m.artist = "";
    const bare = m.trackNotification();
    try testing.expect(bare.title.len > 0);
    try testing.expectEqualStrings("", bare.body);
    try testing.expectEqualStrings("open-player", bare.action_command);
}

test "notifyTrack round-trips through applySettingsJson" {
    var m: Model = .{};
    // Off by default: an existing settings.json has no key, so an update
    // never starts interrupting a listener who did not ask for it.
    try testing.expect(!m.notify_track);

    applySettingsJson(&m, "{\"notifyTrack\":true}");
    try testing.expect(m.notify_track);

    applySettingsJson(&m, "{\"notifyTrack\":false}");
    try testing.expect(!m.notify_track);
}

test "discord settings round-trip through applySettingsJson" {
    var m: Model = .{};
    applySettingsJson(&m, "{\"discordEnabled\":true,\"discordClientId\":\"123456789012345678\"}");
    try testing.expect(m.discord_enabled);
    try testing.expectEqualStrings("123456789012345678", m.discord_client_id);
    try testing.expect(m.discord_configured());
}

test "an invalid discordClientId in settings.json is dropped" {
    var m: Model = .{};
    applySettingsJson(&m, "{\"discordClientId\":\"not-a-snowflake\"}");
    try testing.expectEqualStrings("", m.discord_client_id);
    try testing.expect(!m.discord_configured());
}

test "submitting a valid client ID stores it, enables the feature, and spawns" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    update(&m, .{ .discord_id_edit = .{ .insert_text = " 123456789012345678 " } }, &fx);
    update(&m, .submit_discord_id, &fx);
    try testing.expectEqualStrings("123456789012345678", m.discord_client_id);
    try testing.expect(m.discord_enabled);
    try testing.expectEqualStrings("", m.discord_id_text()); // field cleared for next time
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    // The ID rides the helper's stdin payload.
    const req = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, req.stdin, "\"client_id\":\"123456789012345678\"") != null);
}

test "submitting a malformed client ID complains and changes nothing" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    update(&m, .{ .discord_id_edit = .{ .insert_text = "12345" } }, &fx);
    update(&m, .submit_discord_id, &fx);
    try testing.expect(m.has_discord_id_status());
    try testing.expect(!m.discord_enabled);
    try testing.expectEqualStrings("", m.discord_client_id);
    try testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    // Typing again clears the complaint.
    update(&m, .{ .discord_id_edit = .{ .insert_text = "6" } }, &fx);
    try testing.expect(!m.has_discord_id_status());
}

test "changing the client ID respawns the helper under the new identity" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    testSetDiscordId(&m);
    update(&m, .toggle_discord, &fx);
    const first_key = m.discord_spawn_key;
    update(&m, .{ .discord_id_edit = .{ .insert_text = "987654321098765432" } }, &fx);
    update(&m, .submit_discord_id, &fx);
    try testing.expect(m.discord_spawn_key != first_key);
    const req = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, req.stdin, "\"client_id\":\"987654321098765432\"") != null);
}

test "clearing the client ID cancels the presence when no build default exists" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    testSetDiscordId(&m);
    update(&m, .toggle_discord, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    update(&m, .clear_discord_id, &fx);
    try testing.expect(!m.discord_configured()); // discord.zon default is "" here
    try testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
}

test "helper ERROR lines surface through the status line and READY clears them" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    testSetDiscordId(&m);
    update(&m, .toggle_discord, &fx);
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "ERROR: client id rejected" } }, &fx);
    try testing.expectEqualStrings("Discord rejected the client ID", m.discord_status_line());
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "ERROR: Discord not running" } }, &fx);
    try testing.expectEqualStrings("Discord isn't running", m.discord_status_line());
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "ERROR: activity write failed" } }, &fx);
    try testing.expectEqualStrings("Connection to Discord failed", m.discord_status_line());
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "READY" } }, &fx);
    try testing.expectEqualStrings("Connected", m.discord_status_line());
}

test "saveSettings persists the client ID" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.settings_path = "/tmp/settings.json";
    testSetDiscordId(&m);
    saveSettings(&m, &fx);
    const written = fx.pendingFileAt(0).?;
    try testing.expect(std.mem.indexOf(u8, written.bytes, "\"discordClientId\":\"123456789012345678\"") != null);
}

test "enabling Discord Rich Presence while playing spawns the helper" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    m.artist = "The Midnight";
    update(&m, .toggle_discord, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const req = fx.pendingSpawnAt(0).?;
    try testing.expectEqualStrings(m.self_exe_path, req.argv[0]);
    try testing.expectEqualStrings("--discord-rpc-helper", req.argv[1]);
    try testing.expect(std.mem.indexOf(u8, req.stdin, "Night Drive") != null);
}

test "an unchanged now-playing poll does not respawn the helper" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    m.artist = "The Midnight";
    update(&m, .toggle_discord, &fx);
    const key_after_enable = m.discord_spawn_key;
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Night Drive\",\"artist\":\"The Midnight\"}}" } }, &fx);
    try testing.expectEqual(key_after_enable, m.discord_spawn_key);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
}

test "a track change respawns the helper with the new payload" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    m.artist = "The Midnight";
    update(&m, .toggle_discord, &fx);
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Neon\",\"artist\":\"Purple Sky\"}}" } }, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const req = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, req.stdin, "Neon") != null);
}

test "track elapsed is anchored to when the track actually changed, not the raw stream position" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    m.artist = "The Midnight";
    m.elapsed_ms = 200_000; // continuous stream position, unrelated to this track's own length
    update(&m, .toggle_discord, &fx);
    const req1 = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, req1.stdin, "\"elapsed_ms\":0") != null);

    // Stream position keeps climbing but the track hasn't changed — no
    // respawn (the signature doesn't include elapsed_ms), so nothing new
    // is sent, but if it were, it must not use the raw climbing position.
    m.elapsed_ms = 210_000;
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Night Drive\",\"artist\":\"The Midnight\"}}" } }, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());

    // A real track change re-anchors at whatever the stream position is now.
    m.elapsed_ms = 215_000;
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"nowPlaying\":{\"title\":\"Neon\",\"artist\":\"Purple Sky\"}}" } }, &fx);
    const req2 = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, req2.stdin, "\"elapsed_ms\":0") != null);
}

test "tuning out cancels the helper without respawning" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    update(&m, .toggle_discord, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    update(&m, .tune_out, &fx);
    try testing.expectEqual(@as(usize, 0), fx.pendingSpawnCount());
    try testing.expect(!m.discord_connected);
}

test "a READY line marks connected; a non-cancelled exit schedules a retry" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    update(&m, .toggle_discord, &fx);
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "READY" } }, &fx);
    try testing.expect(m.discord_connected);
    update(&m, .{ .discord_exited = .{ .key = m.discord_spawn_key, .reason = .signaled } }, &fx);
    try testing.expect(!m.discord_connected);
    try testing.expectEqual(@as(u6, 1), m.discord_retry_count);
}

test "a stale exit from a superseded helper does not disturb the current one" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    testSetDiscordId(&m);
    m.transport = .playing;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    m.title = "Night Drive";
    update(&m, .toggle_discord, &fx);
    update(&m, .{ .discord_line = .{ .key = m.discord_spawn_key, .line = "READY" } }, &fx);
    // A pre-respawn helper's natural exit can already be in flight when the
    // keys flip, so it arrives carrying the other key and a non-cancelled
    // reason. It must not clear the signature or schedule a retry — that
    // would kill the healthy current helper on the next retry tick.
    const stale_key = if (m.discord_spawn_key == keys.discord_rpc_a) keys.discord_rpc_b else keys.discord_rpc_a;
    update(&m, .{ .discord_exited = .{ .key = stale_key, .reason = .signaled } }, &fx);
    try testing.expect(m.discord_connected);
    try testing.expectEqual(@as(u6, 0), m.discord_retry_count);
    try testing.expect(m.discord_last_payload.len > 0);
}

test "a new station starts with the format floor after its health check" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.format_pref = .aac;
    m.stream_flags_known = true;
    m.stream_aac = true;
    m.station_buffer.set("radio.example");
    update(&m, .tune_station, &fx);
    try testing.expectEqual(StreamFormat.aac, m.format_pref);
    m.ob_done = true;
    update(&m, .ob_tune_in, &fx);
    try testing.expectEqual(StreamFormat.mp3, m.format_pref);
    try testing.expect(!m.stream_flags_known);
    try testing.expect(!m.stream_aac);
}

test "update check: newer tag arms the notice, older clears it, failures keep state" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // Newer release arms.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v99.0.0\"}" } }, &fx);
    try testing.expectEqualStrings("v99.0.0", m.update_tag);
    try testing.expect(m.update_available());
    // Older (or equal) release disarms — covers a rollback of a bad release.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v0.0.1\"}" } }, &fx);
    try testing.expect(!m.update_available());
    // Failures leave the armed state untouched.
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "{\"tag_name\":\"v99.0.0\"}" } }, &fx);
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .timed_out, .status = 0, .body = "" } }, &fx);
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 403, .body = "rate limited" } }, &fx);
    update(&m, .{ .got_update = .{ .key = keys.fetch_update, .outcome = .ok, .status = 200, .body = "not json" } }, &fx);
    try testing.expect(m.update_available());
}

test "chrome insets land on both edges, so the masthead clears controls on any platform" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    // macOS shape: traffic lights lead, nothing trails.
    update(&m, .{ .chrome_changed = .{ .top = 52, .leading = 78, .trailing = 0 } }, &fx);
    try testing.expectEqual(@as(f32, 52), m.chrome_top);
    try testing.expectEqual(@as(f32, 78), m.chrome_leading);
    try testing.expectEqual(@as(f32, 0), m.chrome_trailing);
    // Windows shape: the min/max/close cluster trails instead. Dropping it is
    // what put the gear button under the DWM caption buttons, whose colour the
    // host samples from the pixel just leading of the cluster every present.
    update(&m, .{ .chrome_changed = .{ .top = 32, .leading = 0, .trailing = 138 } }, &fx);
    try testing.expectEqual(@as(f32, 0), m.chrome_leading);
    try testing.expectEqual(@as(f32, 138), m.chrome_trailing);
}

test "log_dir_value reports the diagnostic log folder" {
    const m: Model = .{};
    // Unopened in the suite, so it reads empty rather than crashing.
    try testing.expectEqualStrings("", m.log_dir_value());
}

test "open_release spawns the opener once until it exits" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .open_release, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try testing.expect(m.opener_inflight);
    // Second click while the opener lives: no second spawn.
    update(&m, .open_release, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    // Exit clears the guard.
    update(&m, .{ .opener_exited = .{ .key = keys.open_release_spawn, .reason = .exited } }, &fx);
    try testing.expect(!m.opener_inflight);
}

test "open_support opens ko-fi behind the same one-opener guard" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    update(&m, .open_support, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    try testing.expect(m.opener_inflight);
    // It is the ko-fi page that got handed to the browser, not the release page.
    const req = fx.pendingSpawnAt(0).?;
    try testing.expectEqualStrings(links.support, req.argv[req.argv.len - 1]);
    // The guard spans links: a release press while ko-fi's opener lives is a no-op.
    update(&m, .open_release, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    update(&m, .{ .opener_exited = .{ .key = keys.open_support_spawn, .reason = .exited } }, &fx);
    try testing.expect(!m.opener_inflight);
}

test "the feed-poll heartbeat resets the audio-event count only every 12th fired tick" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };

    // Audio events are counted, never logged — the arm must not emit per event.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        update(&m, .{ .audio_event = .{ .key = keys.audio, .kind = .position, .position_ms = 1000 } }, &fx);
    }
    try testing.expectEqual(@as(u32, 40), m.hb_audio_events);

    // A tick that did not fire must not touch the count, or the tick counter.
    update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .rejected, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(@as(u32, 40), m.hb_audio_events);
    try testing.expectEqual(@as(u8, 0), m.hb_tick_count);

    // Fired ticks 1 through 11 (5s each = 55s) must fetch the feed every
    // time but must NOT reset the audio-event count — only the 12th (60s)
    // fired tick is the heartbeat.
    var t: usize = 0;
    while (t < 11) : (t += 1) {
        update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
        try testing.expectEqual(@as(u32, 40), m.hb_audio_events);
    }
    try testing.expectEqual(@as(u8, 11), m.hb_tick_count);

    // The 12th fired tick is the heartbeat: the count and the tick counter
    // both reset.
    update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(@as(u32, 0), m.hb_audio_events);
    try testing.expectEqual(@as(u8, 0), m.hb_tick_count);
}

test "fetchFeed's fetch keys occupy their slots on the very first fired tick_feed tick" {
    // The feed poll must never be coupled to the heartbeat's 12-tick divisor
    // — issue #23 review flagged this as the one thing that must not
    // regress when the heartbeat cadence changed. fetchFeed sits outside the
    // 12-tick gate in the .tick_feed arm, so even the first fired tick (long
    // before any heartbeat would fire) must schedule the np/state/session
    // fetches.
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    m.base = "http://example.test";

    try testing.expectEqual(@as(usize, 0), fx.pendingFetchCount());
    update(&m, .{ .tick_feed = .{ .key = keys.feed_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqual(@as(usize, 3), fx.pendingFetchCount());
}

test "station polls derive the offset and reset it when context disappears" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    var clock: native_sdk.TestClock = .{};
    clock.setWallMs((station_time.isoSeconds("2026-10-13T23:50:00Z") orelse unreachable) * 1000);
    m.station_clock = clock.clock();
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{\"timezone\":\"Asia/Kathmandu\",\"locale\":\"en-US\",\"context\":{\"clock\":{\"hhmm\":\"05:35\"},\"date\":{\"dayOfWeek\":3,\"iso\":\"2026-10-14\"}}}" } }, &fx);
    try testing.expectEqual(@as(i64, 345), m.station_offset_minutes);
    try testing.expectEqual(@as(i64, 3), m.selectedDay());
    try testing.expectEqualStrings("Asia/Kathmandu", m.timezone);
    try testing.expectEqual(station_time.Locale.en_us, m.station_locale);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("05:35 AM", m.stationClock(arena.allocator()));
    clock.advanceMs(60_000);
    try testing.expectEqualStrings("05:36 AM", m.stationClock(arena.allocator()));
    update(&m, .{ .pick_day = 1 }, &fx);
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body = "{}" } }, &fx);
    try testing.expectEqual(@as(i64, 0), m.station_offset_minutes);
    try testing.expectEqual(@as(i64, 1), m.selectedDay());
    update(&m, .{ .pick_tab = .schedule }, &fx);
    try testing.expectEqual(@as(i64, 2), m.selectedDay());
}

test "NOW marks only the current range and follows station midnight" {
    var m: Model = .{};
    var clock: native_sdk.TestClock = .{};
    clock.setWallMs((station_time.isoSeconds("2026-10-13T23:59:00Z") orelse unreachable) * 1000);
    m.station_clock = clock.clock();
    m.show_count = 1;
    m.show_rows[0] = .{ .name = "Repeated show" };
    m.sched_grid[2][23] = 1;
    m.sched_grid[3][0] = 1;
    m.sched_grid[3][12] = 1;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var slots = m.day_slots(arena.allocator());
    try testing.expect(!slots[0].on_air);
    try testing.expect(slots[1].on_air);
    clock.advanceMs(60000);
    try testing.expectEqual(@as(i64, 3), m.selectedDay());
    slots = m.day_slots(arena.allocator());
    try testing.expect(slots[0].on_air);
    for (slots[1..]) |row| try testing.expect(!row.on_air);
    m.day_picked = true;
    m.day_sel = 2;
    for (m.day_slots(arena.allocator())) |row| try testing.expect(!row.on_air);
}

test "history selects the aired timestamp and booth formats ISO or epoch in station time" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.station_offset_minutes = 330;
    m.station_locale = .en_us;
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = "{\"history\":[{\"title\":\"Started\",\"startedAt\":\"2026-10-13T23:00:00Z\",\"t\":\"2026-10-13T22:00:00Z\"},{\"title\":\"Legacy\",\"startedAt\":\"bad\",\"t\":\"2026-10-13T22:00:00Z\"},{\"title\":\"Queued\",\"queuedAt\":\"2026-10-13T21:00:00Z\"},{\"title\":\"Missing\"}]}" } }, &fx);
    update(&m, .{ .got_session = .{ .key = keys.fetch_session, .outcome = .ok, .status = 200, .body = "{\"messages\":[{\"role\":\"segment\",\"text\":\"ISO\",\"t\":\"1970-01-01T00:00:01Z\"},{\"role\":\"track\",\"text\":\"Epoch\",\"t\":1000},{\"role\":\"dj\",\"text\":\"No time\"}]}" } }, &fx);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const history = m.history_list(arena.allocator());
    try testing.expectEqualStrings("04:30 AM", history[0].hhmm);
    try testing.expectEqualStrings("03:30 AM", history[1].hhmm);
    try testing.expectEqualStrings("02:30 AM", history[2].hhmm);
    try testing.expectEqualStrings("", history[3].hhmm);
    const turns = m.booth_list(arena.allocator());
    try testing.expectEqualStrings("", turns[0].station_stamp);
    try testing.expectEqualStrings("5:46:40 AM", turns[1].station_stamp);
    try testing.expectEqualStrings("5:30:01 AM", turns[2].station_stamp);
}

test "schedule retains guests and public biographies and maps only kept shows" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.base = "https://station.test";
    update(&m, .{ .got_schedule = .{ .key = keys.fetch_schedule, .outcome = .ok, .status = 200, .body = "{\"timezone\":\"Europe/London\",\"locale\":\"en-US\",\"soulsPublished\":false,\"personas\":[{\"id\":\"h\",\"name\":\"Heer\",\"tagline\":\"After dark\",\"soul\":\"Do not publish\",\"avatar\":\"/persona-avatar/h\"},{\"id\":\"g\",\"name\":\"Sol\"}],\"shows\":[{\"id\":\"skip\"},{\"id\":\"keep\",\"name\":\"Night Static\",\"topic\":\"Records to keep you company\",\"personaId\":\"h\",\"guestPersonaIds\":[\"g\",\"deleted\"]}],\"schedule\":{\"0\":[\"keep\",\"keep\"]}}" } }, &fx);
    try testing.expectEqual(@as(usize, 1), m.show_count);
    try testing.expectEqual(@as(u8, 1), m.sched_grid[0][0]);
    try testing.expectEqualStrings("Sol", m.show_rows[0].guests);
    try testing.expectEqualStrings("", m.persona_roster.rows[0].soul);
    try testing.expectEqualStrings("After dark", m.persona_roster.rows[0].tagline);
    try testing.expectEqual(@as(u64, 0), m.persona_images[0]);
    const id = m.persona_loading[0];
    try testing.expect(id >= keys.persona_image_base);
    try testing.expectEqual(@as(usize, 1), fx.pendingImageLoadCount());
    try testing.expectEqualStrings("https://station.test/api/persona-avatar/h", fx.pendingImageLoadAt(0).?.url);
    update(&m, .{ .got_persona = .{ .id = id, .outcome = .loaded } }, &fx);
    try testing.expectEqual(id, m.persona_images[0]);
    m.day_picked = true;
    m.day_sel = 0;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const slot = m.day_slots(arena.allocator())[0];
    try testing.expectEqualStrings("Records to keep you company", slot.topic);
    try testing.expectEqual(id, slot.avatar_id);
    update(&m, .{ .toggle_slot_topic = 0 }, &fx);
    try testing.expect(m.slot_topic_open[0]);
    update(&m, .{ .pick_day = 1 }, &fx);
    try testing.expect(!m.slot_topic_open[0]);
    // Switching stations clears pixels and clock metadata. A previous load's
    // terminal result must not attach its portrait to the fresh station.
    retune(&m, &fx);
    try testing.expectEqual(@as(usize, 0), m.persona_roster.count);
    try testing.expectEqual(@as(u64, 0), m.persona_images[0]);
    try testing.expectEqualStrings("", m.timezone);
    update(&m, .{ .got_persona = .{ .id = id, .outcome = .loaded } }, &fx);
    try testing.expectEqual(@as(u64, 0), m.persona_images[0]);
}

test "second timer serves visible station panels and survives sleep cancellation" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.phase = .player;
    update(&m, .{ .pick_tab = .schedule }, &fx);
    try testing.expect(m.station_second_timer_active);
    // Polling timers run alongside; only the second timer is under test here.
    try testing.expectEqual(@as(?u64, 1000), timerInterval(&fx, keys.second_timer));
    update(&m, .{ .sleep_pick = 15 }, &fx);
    update(&m, .cancel_sleep, &fx);
    try testing.expect(m.station_second_timer_active);
    update(&m, .close_panel, &fx);
    try testing.expect(!m.station_second_timer_active);
    try testing.expect(timerInterval(&fx, keys.second_timer) == null);
    update(&m, .open_timeline, &fx);
    try testing.expect(m.station_second_timer_active);
    update(&m, .app_deactivated, &fx);
    try testing.expect(!m.station_second_timer_active);
    try testing.expect(timerInterval(&fx, keys.second_timer) == null);
    update(&m, .{ .sleep_pick = 15 }, &fx);
    try testing.expect(m.station_second_timer_active);
    update(&m, .cancel_sleep, &fx);
    try testing.expect(!m.station_second_timer_active);
    update(&m, .app_activated, &fx);
    try testing.expect(m.station_second_timer_active);
}

fn testIso(buf: []u8, now_ms: i64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(now_ms, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,          month_day.month.numeric(), @as(u6, month_day.day_index) + 1,
        time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
    });
}

test "reducer joins feed responses in either order before publishing a held track" {
    inline for (.{ true, false }) |np_first| {
        var fx = Effects.init(testing.allocator);
        defer fx.deinit();
        fx.executor = .fake;
        var m: Model = .{};
        update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body =
            \\{"nowPlaying":{"title":"Audible","artist":"Artist"},"stream":{"bufferSeconds":22}}
        } }, &fx);
        var stamp_buf: [32]u8 = undefined;
        const stamp = try testIso(&stamp_buf, native_sdk.nowMs());
        var state_buf: [256]u8 = undefined;
        const state = try std.fmt.bufPrint(&state_buf, "{{\"current\":{{\"title\":\"Next\",\"artist\":\"Artist\",\"startedAt\":\"{s}\"}}}}", .{stamp});
        const np: Msg = .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body =
            \\{"nowPlaying":{"title":"Next","artist":"Artist"},"stream":{"bufferSeconds":22}}
        } };
        const current: Msg = .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = state } };
        fetchFeed(&m, &fx);
        update(&m, if (np_first) np else current, &fx);
        try testing.expectEqualStrings("Audible", m.title);
        update(&m, if (np_first) current else np, &fx);
        try testing.expectEqualStrings("Audible", m.title);
        const release = m.listener.current_start_ms.? + 22_000;
        refreshListener(&m, &fx, release - 1);
        try testing.expectEqualStrings("Audible", m.title);
        refreshListener(&m, &fx, release);
        try testing.expectEqualStrings("Next", m.title);
        try testing.expectEqual(@as(i64, 0), m.track_elapsed_ms);
        refreshTrackElapsed(&m, release + 13_000);
        try testing.expectEqual(@as(i64, 13_000), m.track_elapsed_ms);
    }
}

test "a failed or malformed state leg completes the feed join" {
    inline for (.{ "not json", "{}" }) |body| {
        var fx = Effects.init(testing.allocator);
        defer fx.deinit();
        fx.executor = .fake;
        var m: Model = .{};
        fetchFeed(&m, &fx);
        update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body =
            \\{"nowPlaying":{"title":"First track"},"stream":{"bufferSeconds":22}}
        } }, &fx);
        try testing.expectEqualStrings("Tuning in…", m.title);
        update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .ok, .status = 200, .body = body } }, &fx);
        try testing.expectEqualStrings("First track", m.title);
        try testing.expect(!m.listener.waiting_np and !m.listener.waiting_state);
        fetchFeed(&m, &fx);
        update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .timed_out, .status = 0, .body = "" } }, &fx);
        update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .timed_out, .status = 0, .body = "" } }, &fx);
        try testing.expect(!m.listener.waiting_np and !m.listener.waiting_state);
    }
}

test "station switch clears the listener hold and ignores old feed terminals" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.listener.receiveTrack(.{ .title = "Old station" }, 22, 100_000);
    refreshListener(&m, &fx, 100_000);
    m.listener.receiveTrack(.{ .title = "Held", .legacy_start_ms = 105_000 }, 22, 105_000);
    refreshListener(&m, &fx, 105_000);
    update(&m, .{ .pick_recent = "https://new.example" }, &fx);
    try testing.expectEqualStrings("Tuning in…", m.title);
    try testing.expectEqual(@as(i64, 0), m.listener.lead_ms);
    try testing.expect(!m.listener.live_known);
    try testing.expect(m.listener_np_key >= 50 and m.listener_np_key <= 59);
    update(&m, .{ .got_np = .{ .key = keys.fetch_np, .outcome = .ok, .status = 200, .body =
        \\{"nowPlaying":{"title":"Old terminal"}}
    } }, &fx);
    update(&m, .{ .got_state = .{ .key = keys.fetch_state, .outcome = .cancelled, .status = 0, .body = "" } }, &fx);
    try testing.expect(m.listener.waiting_np and m.listener.waiting_state);
    try testing.expectEqualStrings("Tuning in…", m.title);
}

test "booth decoding holds speech and displays carried tail and boundary only" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.listener.lead_ms = 22_000;
    m.title = "Song";
    m.artist = "Song artist";
    m.host = "Heer";
    testSetDiscordId(&m);
    m.discord_enabled = true;
    m.self_exe_path = "/usr/local/bin/subwave-desktop";
    var stamp_buf: [32]u8 = undefined;
    const stamp = try testIso(&stamp_buf, native_sdk.nowMs());
    const aired = iso8601.parseMs(stamp).?;
    var body_buf: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"messages\":[" ++
        "{{\"t\":123,\"role\":\"segment\",\"text\":\"Goodnight from Bob\",\"meta\":{{\"carried\":true,\"personaName\":\"Bob\",\"ignored\":true}}}}," ++
        "{{\"role\":\"event\",\"kind\":\"show-boundary\",\"text\":\"Server fallback\",\"meta\":{{\"boundary\":{{\"at\":\"2026-10-09T12:00:00Z\",\"show\":\"Blue Hour\",\"persona\":\"Heer\"}}}}}}," ++
        "{{\"role\":\"event\",\"kind\":\"scenario\",\"text\":\"Internal event\"}}," ++
        "{{\"t\":\"{s}\",\"role\":\"segment\",\"kind\":\"link\",\"text\":\"Welcome in\",\"meta\":{{\"airedAt\":\"{s}\",\"durationMs\":14000}}}}]}}", .{ stamp, stamp });
    update(&m, .{ .got_session = .{ .key = keys.fetch_session, .outcome = .ok, .status = 200, .body = body } }, &fx);
    try testing.expectEqual(@as(usize, 4), m.raw_booth_count);
    try testing.expectEqual(@as(usize, 2), m.booth_count);
    try testing.expectEqualStrings("", m.booth_line);
    try testing.expect(m.booth_turns[0].is_boundary);
    try testing.expectEqualStrings("12:00 · Blue Hour", m.booth_turns[0].text);
    try testing.expect(m.booth_turns[1].is_carried);
    try testing.expectEqualStrings("Bob", m.booth_turns[1].persona);
    try testing.expectEqualStrings("Song artist", m.presentation_artist());
    refreshListener(&m, &fx, aired + 22_000);
    try testing.expectEqual(@as(usize, 3), m.booth_count);
    try testing.expectEqualStrings("Welcome in", m.booth_line);
    try testing.expect(m.dj_talking);
    try testing.expectEqualStrings("Heer", m.presentation_artist());
    try testing.expectEqualStrings("Song artist", m.artist);
    try testing.expectEqualStrings("Song — Heer", m.tray_track);
    const request = fx.pendingSpawnAt(0).?;
    try testing.expect(std.mem.indexOf(u8, request.stdin, "\"state\":\"Heer\"") != null);
    refreshListener(&m, &fx, aired + 36_000);
    try testing.expect(!m.dj_talking);
    try testing.expectEqualStrings("Song — Song artist", m.tray_track);
    try testing.expectEqualStrings("Song artist", m.presentation_artist());
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    m.booth_filter = .tracks;
    try testing.expectEqual(@as(usize, 1), m.booth_list(arena_state.allocator()).len);
}

test "hidden latest booth turns cannot evict audible turns before the row cap" {
    var m: Model = .{};
    m.listener.lead_ms = 22_000;
    m.raw_booth[0].class = .voice;
    m.raw_booth[0].text.set("Audible old line");
    for (m.raw_booth[1..33]) |*turn| {
        turn.class = .voice;
        turn.text.set("Still buffered");
        turn.aired_at_ms = 100_000;
    }
    m.raw_booth_count = 33;
    refreshBooth(&m, 105_000);
    try testing.expectEqual(@as(usize, 1), m.booth_count);
    try testing.expectEqualStrings("Audible old line", m.booth_line);
}

test "likes during a hold post the audible song and leave a 409 unchanged" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.listener.receiveTrack(.{ .title = "Audible", .song_id = "old" }, 22, 100_000);
    refreshListener(&m, &fx, 100_000);
    m.like_available = true;
    m.like_count = 5;
    m.listener.receiveTrack(.{ .title = "Next", .song_id = "new", .legacy_start_ms = 105_000 }, 22, 105_000);
    refreshListener(&m, &fx, 105_000);
    update(&m, .press_like, &fx);
    try testing.expect(m.like_pending);
    try testing.expect(std.mem.startsWith(u8, &m.like_body_buf, "{\"songId\":\"old\"}"));
    update(&m, .{ .got_like_post = .{ .key = keys.post_like, .outcome = .ok, .status = 409, .body = "{}" } }, &fx);
    try testing.expect(!m.like_pending and m.like_available and !m.like_liked);
    try testing.expectEqual(@as(u32, 5), m.like_count);
    update(&m, .{ .got_like_status = .{ .key = m.listener_like_key, .outcome = .ok, .status = 200, .body =
        \\{"enabled":true,"songId":"new","liked":true,"count":9}
    } }, &fx);
    try testing.expectEqual(@as(u32, 5), m.like_count);
    refreshListener(&m, &fx, 127_000);
    try testing.expectEqualStrings("Next", m.title);
    try testing.expectEqualStrings("new", m.cover_sid);
    try testing.expectEqualStrings("new", m.like_song);
    try testing.expect(!m.like_available and !m.like_liked);
    try testing.expectEqual(@as(u32, 0), m.like_count);
}

test "boundary labels fall back to server text and malformed voice metadata fails open" {
    var turn: listener_time.Turn = .{};
    const parsed = try json.parse(json.Session, testing.allocator,
        \\{"messages":[{"role":"event","kind":"show-boundary","text":"Server clock · Show","meta":{"boundary":{"at":"invalid","show":"Show"}}},{"t":100000,"role":"segment","kind":"link","text":"one two three four five six seven eight nine ten","meta":{"airedAt":123,"durationMs":"bad","carried":"true"}}]}
    );
    defer parsed.deinit();
    var m: Model = .{};
    for (parsed.value.messages.?, 0..) |message, i| decodeBoothTurn(&m.raw_booth[i], message);
    m.raw_booth_count = 2;
    refreshBooth(&m, 100_000);
    try testing.expectEqualStrings("Server clock · Show", m.booth_turns[1].text);
    turn = m.raw_booth[1];
    try testing.expect(turn.aired_at_ms == null and !turn.carried);
    try testing.expectEqual(@as(i64, 5046), turn.duration_ms);
    try testing.expect(m.dj_talking);
}

test "station switch ignores old booth terminals and the listener tick survives sleep cancellation" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    startPlayerTimers(&m, &fx);
    armSleep(&m, &fx, 15);
    disarmSleep(&m, &fx);
    update(&m, .{ .pick_recent = "https://new.example" }, &fx);
    update(&m, .{ .got_session = .{ .key = keys.fetch_session, .outcome = .ok, .status = 200, .body =
        \\{"messages":[{"role":"segment","text":"Old station"}]}
    } }, &fx);
    try testing.expectEqual(@as(usize, 0), m.raw_booth_count);
    m.raw_booth[0].class = .voice;
    m.raw_booth[0].text.set("Current station");
    m.raw_booth_count = 1;
    update(&m, .{ .tick_listener = .{ .key = keys.listener_timer, .outcome = .fired, .timestamp_ns = 0 } }, &fx);
    try testing.expectEqualStrings("Current station", m.booth_line);
}

test "track promotion fetches likes on a fresh key while the previous GET is outstanding" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    m.listener.receiveTrack(.{ .title = "First", .song_id = "first" }, 0, 100_000);
    refreshListener(&m, &fx, 100_000);
    const first_key = m.listener_like_key;
    m.listener.receiveTrack(.{ .title = "Second", .song_id = "second" }, 0, 105_000);
    refreshListener(&m, &fx, 105_000);
    try testing.expect(m.listener_like_key != first_key);
    var fetched = false;
    for (0..fx.pendingFetchCount()) |index| {
        if (fx.pendingFetchAt(index).?.key == m.listener_like_key) fetched = true;
    }
    try testing.expect(fetched);
    update(&m, .{ .got_like_status = .{ .key = first_key, .outcome = .ok, .status = 200, .body =
        \\{"enabled":true,"songId":"first","liked":true,"count":20}
    } }, &fx);
    try testing.expect(!m.like_available);
    update(&m, .{ .got_like_status = .{ .key = m.listener_like_key, .outcome = .ok, .status = 200, .body =
        \\{"enabled":true,"songId":"second","liked":false,"count":3}
    } }, &fx);
    try testing.expect(m.like_available);
    try testing.expectEqual(@as(u32, 3), m.like_count);
}

fn testDrainEffects(model: *Model, fx: *Effects) !void {
    while (fx.takeMsg()) |message| {
        switch (message) {
            .got_np, .got_state, .got_like_status => |reply| try testing.expect(reply.outcome != .rejected),
            else => {},
        }
        update(model, message, fx);
    }
}

test "rapid station switches wait for cancelled keys and ignore old generations" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    inline for (.{ "first.example", "second.example", "third.example" }) |station| {
        update(&m, .{ .pick_recent = "https://" ++ station }, &fx);
    }
    try testing.expect(m.listener_feed_deferred);
    try testing.expect(!m.listener.waiting_np and !m.listener.waiting_state);
    try testDrainEffects(&m, &fx);
    try testing.expect(!m.listener_feed_deferred);
    try testing.expect(m.listener.waiting_np and m.listener.waiting_state);
    try testing.expect(!m.listener.live_known);
    try testing.expectEqualStrings("Tuning in…", m.title);
    try fx.feedResponseOutcome(m.listener_np_key, .ok, 200,
        \\{"nowPlaying":{"title":"Third station"},"stream":{"bufferSeconds":0}}
    );
    try fx.feedResponseOutcome(m.listener_state_key, .ok, 200, "{}");
    try testDrainEffects(&m, &fx);
    try testing.expectEqualStrings("Third station", m.title);
}

test "rapid promotions defer a reused like key until its old terminal drains" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{};
    inline for (.{ "First", "Second", "Third" }, 0..) |title, index| {
        const now_ms: i64 = 100_000 + @as(i64, index) * 1000;
        m.listener.receiveTrack(.{ .title = title, .song_id = title }, 0, now_ms);
        refreshListener(&m, &fx, now_ms);
    }
    try testing.expect(m.listener_like_deferred);
    try testDrainEffects(&m, &fx);
    try testing.expect(!m.listener_like_deferred);
    try fx.feedResponseOutcome(m.listener_like_key, .ok, 200,
        \\{"enabled":true,"songId":"Third","liked":false,"count":3}
    );
    try testDrainEffects(&m, &fx);
    try testing.expect(m.like_available);
    try testing.expectEqual(@as(u32, 3), m.like_count);
}

test "a saved public-HTTP recent retunes directly; a new one goes through consent" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player };
    pushRecent(&m, "Saved", "http://radio.example");
    update(&m, .{ .pick_recent = "http://radio.example" }, &fx);
    try testing.expectEqualStrings("http://radio.example", m.base);
    try testing.expectEqual(Phase.player, m.phase);
    update(&m, .{ .pick_discover = "http://other.example" }, &fx);
    try testing.expectEqualStrings("http://radio.example", m.base);
    try testing.expectEqual(Phase.onboarding, m.phase);
    try testing.expectEqualStrings("http://other.example", m.ob_target_url);
}

test "only a listenerAuth stream arms the stuck-reconnect password re-check" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var m: Model = .{ .phase = .player, .transport = .playing, .auth_gate = .ok, .privacy_private = true };
    setStr(&m.station_pw_buf, &m.station_pw, "saved-secret");
    armAuthRecheck(&m, &fx);
    try testing.expect(m.auth_recheck.reconnect_since == null);
    m.privacy_listener_auth = true;
    armAuthRecheck(&m, &fx);
    try testing.expect(m.auth_recheck.reconnect_since != null);
}

test "DJ talk swaps in the show host, never the bare DJ name" {
    var m: Model = .{};
    m.artist = "Song artist";
    m.dj = "Frequency";
    m.dj_talking = true;
    try testing.expectEqualStrings("Song artist", m.presentation_artist());
    m.host = "Heer";
    try testing.expectEqualStrings("Heer", m.presentation_artist());
}
