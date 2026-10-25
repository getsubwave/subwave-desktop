const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

// Pull the pure modules' unit tests into the suite.
comptime {
    _ = @import("color.zig");
    _ = @import("spectrum.zig");
    _ = @import("api.zig");
    _ = @import("update.zig");
    _ = @import("links.zig");
    _ = @import("distribution.zig");
    _ = @import("diag.zig");
    _ = @import("model.zig");
    _ = @import("stream_format.zig");
    _ = @import("station_access.zig");
    _ = @import("theme.zig");
    _ = @import("discord_rpc.zig");
    _ = @import("station_time.zig");
    _ = @import("station_schedule.zig");
    _ = @import("listener_time.zig");
    _ = @import("lyrics.zig");
    _ = @import("iso8601.zig");
    _ = @import("utf8.zig");
    _ = @import("request_suggestions.zig");
    _ = @import("polling.zig");
    _ = @import("directory_status.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

const onboarding_markup = @embedFile("views/onboarding.native");
const lock_markup = @embedFile("views/lock.native");
const mini_markup = @embedFile("views/mini.native");
const player_top_markup = @embedFile("views/player-top.native");
const player_sidebar_markup = @embedFile("views/player-sidebar.native");
const player_stage_markup = @embedFile("views/player-stage.native");
const player_panel_markup = @embedFile("views/player-panel.native");
const player_deck_markup = @embedFile("views/player-deck.native");
const player_sheets_markup = @embedFile("views/player-sheets.native");

// `main()` registers the app icon table before any view builds; the suite has
// no main(), so without this every `icon="app:logo"` in the fragments below
// resolved to the missing-icon fallback and the run buried the real output
// under "unknown icon" warnings. Registering here makes the suite exercise the
// same name lookup the app does — a fragment naming an icon that is not in
// `main.app_icons` now shows up as a warning in `native test`, where it can be
// noticed, instead of drawing a slashed circle at runtime.
fn registerAppIcons() void {
    const State = struct {
        var done = false;
    };
    if (State.done) return;
    canvas.icons.registerAppIcons(&main.app_icons);
    State.done = true;
}

fn buildAndLayout(arena: std.mem.Allocator, source: []const u8, model: *const Model, w: f32, h: f32) !void {
    registerAppIcons();
    var view = try AppMarkup.init(arena, source);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("markup {d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    const tree = try ui.finalize(node);
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, w, h), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

// Every view must bind cleanly to the Model and lay out — a field drift
// becomes a build error here (and, via CompiledMarkupView in views.zig, at
// app build).
test "player fragments build and lay out (every panel + sheets)" {
    var model: Model = .{};
    model.phase = .player;
    model.sidebar_open = true;
    inline for (.{ player_top_markup, player_sidebar_markup, player_stage_markup, player_deck_markup }) |source| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try buildAndLayout(arena_state.allocator(), source, &model, 980, 660);
    }
    // The stage again with every optional run present: real cover pixels, the
    // like heart armed and liked, the token meter, and both metadata halves so
    // meta_mood_sep renders. The default model exercises the empty arms above.
    {
        var arena_stage = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_stage.deinit();
        var loaded: Model = model;
        loaded.cover_id = 1000;
        loaded.like_available = true;
        loaded.like_liked = true;
        loaded.like_count = 42;
        loaded.llm_tokens = 1_234_567;
        loaded.genre = "SOUNDTRACK";
        loaded.track_bpm = 99;
        loaded.moods = "reflective";
        loaded.energy = "low";
        loaded.booth_line = "Blue Hour with Heer";
        try buildAndLayout(arena_stage.allocator(), player_stage_markup, &loaded, 980, 660);
    }
    // Section panel: every tab branch must build.
    inline for (.{ .schedule, .timeline, .booth, .request }) |tab| {
        var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena2.deinit();
        model.active_tab = tab;
        try buildAndLayout(arena2.allocator(), player_panel_markup, &model, 980, 660);
    }
    // Sheets: every surface must build.
    inline for (.{ .panel, .sleep, .themes }) |sheet| {
        var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena3.deinit();
        model.sheet = sheet;
        model.sleep_deadline_ms = 1;
        try buildAndLayout(arena3.allocator(), player_sheets_markup, &model, 980, 660);
    }
    // Discord sheet: unconfigured default, then a saved listener ID + off,
    // then enabled, then with an input complaint showing.
    model.sheet = .discord;
    {
        var arena4 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena4.deinit();
        try buildAndLayout(arena4.allocator(), player_sheets_markup, &model, 980, 660);
    }
    const test_discord_id = "123456789012345678";
    @memcpy(model.discord_client_id_buf[0..test_discord_id.len], test_discord_id);
    model.discord_client_id = model.discord_client_id_buf[0..test_discord_id.len];
    {
        var arena4b = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena4b.deinit();
        try buildAndLayout(arena4b.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.discord_enabled = true;
    model.discord_id_status = "That doesn't look like an application ID (17-20 digits)";
    {
        var arena5 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena5.deinit();
        try buildAndLayout(arena5.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.discord_client_id = "";
    model.discord_enabled = false;
    model.discord_id_status = "";
    // Format sheet with a real choice on offer (station serves AAC).
    model.sheet = .format;
    model.stream_flags_known = true;
    model.stream_aac = true;
    {
        var arena6 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena6.deinit();
        try buildAndLayout(arena6.allocator(), player_sheets_markup, &model, 980, 660);
    }
    // Update notice: panel SERVICE row + top-bar dot with a known newer tag.
    model.update_tag = "v9.9.9";
    model.sheet = .panel;
    {
        var arena7 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena7.deinit();
        try buildAndLayout(arena7.allocator(), player_sheets_markup, &model, 980, 660);
    }
    {
        var arena8 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena8.deinit();
        try buildAndLayout(arena8.allocator(), player_top_markup, &model, 980, 660);
    }
    model.update_tag = "";
    // Mac App Store build: the panel without its SUPPORT section.
    model.support_link = false;
    {
        var arena9 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena9.deinit();
        try buildAndLayout(arena9.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.support_link = true;
    // The station has its Lyrics panel on: the switch, the note on what this
    // track has, and the device timing row with a nudge to reset.
    model.lyrics_enabled = true;
    model.lyrics_device_offset_ms = -300;
    {
        var arena10 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena10.deinit();
        try buildAndLayout(arena10.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.lyrics_enabled = false;
    model.lyrics_device_offset_ms = 0;
}

// The dial strip carries full words (SHOWS / TIMELINE / LIVE / BOOTH /
// REQUEST), which is roughly half again the width the old SHWS/TML/BTH
// abbreviations took. It is centered in its own full-width band, so it cannot
// collide with the masthead — but it CAN outgrow the window, and the toolkit
// has no responsive breakpoints to save it. The narrowest the window ever gets
// is app.zon's min_width, so pin the check there. A live `native automate
// resize` cannot verify this (the SDK relayouts a resized window only at the
// next launch), which is exactly why it belongs in the suite.
test "dial strip fits the minimum window width" {
    const min_width: f32 = 880; // app.zon .shell.windows[0].min_width
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: Model = .{};
    model.phase = .player;

    registerAppIcons();
    var view = try AppMarkup.init(arena, player_top_markup);
    var ui = AppUi.init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, min_width, 660), &nodes);

    var dial_width: f32 = 0;
    var tabs: usize = 0;
    for (layout.nodes) |node| {
        // Nothing in the masthead band may run off the right edge.
        try testing.expect(node.frame.x + node.frame.width <= min_width + 0.5);
        if (std.mem.eql(u8, node.widget.semantics.label, "Dial")) dial_width = node.frame.width;
        if (node.widget.kind == .segmented_control) tabs += 1;
    }
    // All five stops present, lowered to segmented triggers (a `<button>` that
    // stopped being a `<tabs>` child would silently lose the track treatment).
    try testing.expectEqual(@as(usize, model_dial_stops_len), tabs);
    try testing.expect(dial_width > 0);
    // Comfortably inside the band rather than merely fitting: if a future
    // rename pushes the strip past this, it needs a layout decision, not a
    // slightly wider assertion.
    try testing.expect(dial_width <= min_width * 0.6);
}

const model_dial_stops_len = @typeInfo(@TypeOf(Model.dial_stops)).array.len;

test "station panels lay out in both locales, with disclosures and avatar states" {
    const model_module = @import("model.zig");
    const station_time = @import("station_time.zig");
    var fx = model_module.Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var model: Model = .{};
    var clock: native_sdk.TestClock = .{};
    clock.setWallMs((station_time.isoSeconds("2026-10-13T23:00:00Z") orelse unreachable) * 1000);
    model.station_clock = clock.clock();
    model.phase = .player;
    model.station_offset_minutes = 330;
    model.station_loc = "Calcutta";
    model_module.update(&model, .{ .got_schedule = .{
        .key = model_module.keys.fetch_schedule, .outcome = .ok, .status = 200,
        .body =
        \\{"timezone":"Asia/Calcutta","locale":"en-US","soulsPublished":true,
        \\ "personas":[{"id":"host","name":"Heer","tagline":"Records after dark.","soul":"A published host biography.","avatar":"/persona-avatar/host"},{"id":"guest","name":"Sol"}],
        \\ "shows":[{"id":"night","name":"Night Static","personaId":"host","guestPersonaIds":["guest"],"topic":"An extended show description that needs a disclosure so the listener can read every word. This part keeps the text long enough to exercise MORE and LESS in the ON NOW card as well as in the schedule slot."}],
        \\ "schedule":{"3":["night","night","night","night","night"]}}
        ,
    } }, &fx);
    model.show = "Night Static";
    model.host = "Heer";
    model.host_id = "host";
    model.now_guests = "Sol";
    model.history_count = 2;
    model.history_rows[0] = .{ .title = "Aired track", .artist = "Heer", .played_at_s = station_time.isoSeconds("2026-10-13T22:50:00Z") };
    model.history_rows[1] = .{ .title = "Unknown airing", .artist = "Sol" };
    model.booth_count = 3;
    model.booth_turns[0] = .{ .kind = "VOICE", .is_voice = true, .text = "It is half past four.", .stamp_epoch_s = station_time.isoSeconds("2026-10-13T23:00:00Z") };
    model.booth_turns[1] = .{ .kind = "TRACK", .is_track = true, .text = "Title · Artist", .stamp_epoch_s = station_time.isoSeconds("2026-10-13T22:50:00Z") };
    model.booth_turns[2] = .{ .kind = "PICK", .text = "Picking a record." };

    inline for (.{ .en_gb, .en_us }) |display_locale| {
        model.station_locale = display_locale;
        inline for (.{ false, true }) |expanded| {
            model.slot_topic_open[0] = expanded;
            model.slot_host_open[0] = expanded;
            model.now_topic_open = expanded;
            model.now_host_open = expanded;
            model.persona_images[0] = if (expanded) model_module.keys.persona_image_base else 0;
            inline for (.{ .schedule, .timeline, .booth }) |tab| {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                model.active_tab = tab;
                try buildAndLayout(arena.allocator(), player_panel_markup, &model, 380, 560);
            }
        }
    }
    // A browsed day must not borrow today's NOW marker. Guests can also air
    // without a host, and private souls must not produce an ABOUT control.
    model.day_picked = true;
    model.day_sel = 4;
    model.host = "";
    model.host_id = "";
    model.persona_roster.rows[0].soul = "";
    model.active_tab = .schedule;
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), player_panel_markup, &model, 380, 560);
    }
    model.show = "";
    model.timezone = "";
    model.station_loc = "";
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), player_panel_markup, &model, 380, 560);
    }
}

test "station lists lay out with pending, on-air and offline row status" {
    const api = @import("api.zig");
    var model: Model = .{};
    model.recents[0] = .{ .name = "Recent", .url = "https://recent.test" };
    model.recents_count = 1;
    model.discover_rows[0] = .{ .name = "Discover", .url = "https://discover.test", .sub = "London · Jazz" };
    model.discover_count = 1;
    model.directory_status.want(api.default_base);
    model.directory_status.want(model.recents[0].url);
    model.directory_status.want(model.discover_rows[0].url);
    for (0..3) |state| {
        if (state > 0) for (&model.directory_status.entries) |*entry| {
            if (entry.wanted) entry.setStatus(state == 1, "An artist with a long name", "A title that must ellipsize within the station row");
        };
        model.phase = .onboarding;
        var onboarding_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer onboarding_arena.deinit();
        try buildAndLayout(onboarding_arena.allocator(), onboarding_markup, &model, 880, 560);
        model.phase = .player;
        model.sidebar_open = true;
        var sidebar_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer sidebar_arena.deinit();
        try buildAndLayout(sidebar_arena.allocator(), player_sidebar_markup, &model, 320, 560);
    }
}

test "request panel lays out one fallback chip and all five context chips" {
    var model: Model = .{ .phase = .player, .active_tab = .request };
    var fallback_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer fallback_arena.deinit();
    try buildAndLayout(fallback_arena.allocator(), player_panel_markup, &model, 380, 560);
    model.artist = "Björk";
    model.ctx_festival = "Diwali";
    model.ctx_vibe = "slow burn";
    model.ctx_cond = "rain";
    var full_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer full_arena.deinit();
    try buildAndLayout(full_arena.allocator(), player_panel_markup, &model, 380, 560);
}

test "composed player view (every fragment) builds and lays out" {
    const views = @import("views.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: Model = .{};
    model.phase = .player;
    model.sidebar_open = true;
    model.active_tab = .booth;
    // Armed + liked like state so the stage's heart row is in the layout.
    model.like_available = true;
    model.like_liked = true;
    model.like_count = 3;
    registerAppIcons();
    var ui = AppUi.init(arena);
    const tree = try ui.finalize(views.rootView(&ui, &model));
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 980, 660), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "onboarding view builds in entry and check phases" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    try buildAndLayout(arena_state.allocator(), onboarding_markup, &model, 980, 660);
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    model.ob_checking = true;
    model.ob_steps = .{ .ok, .ok, .run, .wait };
    try buildAndLayout(arena2.allocator(), onboarding_markup, &model, 980, 660);
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    model.ob_steps = .{ .ok, .ok, .ok, .ok };
    model.ob_done = true;
    try buildAndLayout(arena3.allocator(), onboarding_markup, &model, 980, 660);
}

test "station access warnings and diagnostics build at the minimum window size" {
    var model: Model = .{};
    model.ob_checking = true;
    model.ob_steps = .{ .ok, .ok, .ok, .ok };
    model.ob_done = true;
    model.ob_insecure = true;
    model.ob_target_name = "Public station";
    model.ob_target_url = "http://radio.example";
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), onboarding_markup, &model, 880, 560);
    }
    model.ob_done = false;
    model.ob_steps = .{ .ok, .fail, .wait, .wait };
    model.ob_diag = "The station asked for a login (HTTP 401). HTTP Basic Station login is not supported by this desktop player.";
    model.ob_raw = "ok (HTTP 401)";
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), onboarding_markup, &model, 880, 560);
    }
    model.ob_checking = false;
    model.station_status = "HTTP Basic Station login is not supported by this desktop player.";
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), onboarding_markup, &model, 880, 560);
    }
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try buildAndLayout(arena.allocator(), player_sidebar_markup, &model, 880, 560);
    }
}

test "lock view builds in prompt, error, and checking states" {
    var model: Model = .{};
    model.phase = .player;
    model.privacy_private = true;
    model.auth_gate = .prompt;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try buildAndLayout(arena_state.allocator(), lock_markup, &model, 980, 660);
    // Wrong-password error line present.
    model.auth_status = "That password was not accepted.";
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    try buildAndLayout(arena2.allocator(), lock_markup, &model, 980, 660);
    // Stored-password re-validation spinner.
    model.auth_status = "";
    model.auth_gate = .checking;
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    try buildAndLayout(arena3.allocator(), lock_markup, &model, 980, 660);
    // And through the composed root: a locked player renders the gate.
    const views = @import("views.zig");
    model.auth_gate = .prompt;
    var arena4 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena4.deinit();
    var ui = AppUi.init(arena4.allocator());
    const tree = try ui.finalize(views.rootView(&ui, &model));
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 980, 660), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

test "mini view builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    model.mini_open = true;
    try buildAndLayout(arena_state.allocator(), mini_markup, &model, 420, 168);
    // Both heart branches of the transport row.
    model.like_available = true;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    try buildAndLayout(arena2.allocator(), mini_markup, &model, 420, 168);
    model.like_liked = true;
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    try buildAndLayout(arena3.allocator(), mini_markup, &model, 420, 168);

    model.dj_talking = true;
    model.host = "Heer";
    var arena4 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena4.deinit();
    try buildAndLayout(arena4.allocator(), mini_markup, &model, 420, 168);
}

test "booth carried tail and boundary branches build and lay out in every filter" {
    var model: Model = .{};
    model.phase = .player;
    model.active_tab = .booth;
    model.booth_turns[0] = .{ .hhmm = "20:02", .text = "Welcome in.", .kind = "VOICE", .is_voice = true };
    model.booth_turns[1] = .{ .text = "20:00 · Blue Hour", .is_boundary = true };
    model.booth_turns[2] = .{ .hhmm = "19:59", .text = "Goodnight from Bob.", .kind = "VOICE", .is_voice = true, .is_carried = true, .persona = "Bob" };
    model.booth_turns[3] = .{ .hhmm = "19:58", .text = "Last pick.", .kind = "PICK", .is_carried = true, .persona = "Bob" };
    model.booth_turns[4] = .{ .hhmm = "19:57", .text = "Song · Artist", .kind = "TRACK", .is_track = true, .is_carried = true, .persona = "Bob" };
    model.booth_turns[5] = .{ .hhmm = "20:01", .text = "Song · Artist", .kind = "TRACK", .is_track = true };
    model.booth_turns[6] = .{ .hhmm = "20:01", .text = "Picked this.", .kind = "PICK" };
    model.booth_count = 7;
    inline for (.{ .all, .dj, .tracks }) |filter| {
        model.booth_filter = filter;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try buildAndLayout(arena_state.allocator(), player_panel_markup, &model, 880, 560);
    }
}

// Lyrics share the LIVE stage with the track, so it has to hold three lines
// of them, a long one wrapped, down to app.zon's minimum window, and lay out
// as cleanly for an intro's rest, the untimed scroller, and the band held
// empty while the next track's lyrics load. The SDK's layout audit referees:
// no paragraph painting past its box, no overlap, nothing leaving the window.
test "lyrics fit the LIVE stage from the minimum window up" {
    const views = @import("views.zig");
    const LyricLine = @import("json.zig").LyricLine;
    var synced = [_]LyricLine{
        .{ .startMs = 0, .text = "The line before this one" },
        .{ .startMs = 1_000, .text = "A rather long line that is being sung right now and might well wrap onto a second line here" },
        .{ .startMs = 9_000, .text = "The next line waiting" },
    };
    var plain: [40]LyricLine = undefined;
    for (&plain, 0..) |*line, i| line.* = .{ .text = if (i % 5 == 4) "" else "A line with no timing, to read by hand" };
    inline for (.{ .{ 880, 560 }, .{ 980, 660 } }) |size| {
        inline for (.{ "synced", "resting", "plain", "held" }) |case| {
            var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var model: Model = .{ .phase = .player, .lyrics_enabled = true };
            model.title = "A Rather Long Title For The Song";
            model.artist = "Artist";
            model.album = "Album";
            model.genre = "AMBIENT";
            model.moods = "calm";
            model.booth_line = "Talking over the intro";
            model.stream_failed = true; // the state line, the tallest the column gets
            model.like_available = true;
            model.track_lyrics.begin("s1");
            if (std.mem.eql(u8, case, "synced") or std.mem.eql(u8, case, "resting")) {
                _ = model.track_lyrics.accept(.{ .songId = "s1", .synced = true, .lines = &synced });
                model.track_elapsed_ms = if (std.mem.eql(u8, case, "synced")) 2_000 else 60_000;
            } else if (std.mem.eql(u8, case, "plain")) {
                _ = model.track_lyrics.accept(.{ .songId = "s1", .synced = false, .lines = &plain });
            } else {
                model.lyrics_held = true;
            }
            try testing.expect(model.lyrics_layout());
            registerAppIcons();
            var ui = AppUi.init(arena);
            const tree = try ui.finalize(views.rootView(&ui, &model));
            var nodes: [1024]canvas.WidgetLayoutNode = undefined;
            const bounds = native_sdk.geometry.RectF.init(0, 0, size[0], size[1]);
            const layout = try canvas.layoutWidgetTree(tree.root, bounds, &nodes);
            var storage: [16]canvas.LayoutAuditFinding = undefined;
            const issues = canvas.auditWidgetLayout(layout, bounds, .{}, &storage);
            for (issues.findings) |finding| {
                var buffer: [1024]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                canvas.formatLayoutAuditFinding(layout, finding, &writer) catch {};
                std.debug.print("{d}x{d} {s}: {s}\n", .{ size[0], size[1], case, writer.buffered() });
            }
            try testing.expectEqual(@as(usize, 0), issues.total);
            // The spectrum keeps its full height under the band.
            var spectrum_height: f32 = 0;
            for (layout.nodes) |node| {
                if (std.mem.eql(u8, node.widget.semantics.label, "Spectrum")) spectrum_height = node.frame.height;
            }
            try testing.expectEqual(@as(f32, 44), spectrum_height);
        }
    }
}
