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
    _ = @import("model.zig");
    _ = @import("stream_format.zig");
    _ = @import("discord_rpc.zig");
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
    // Discord sheet: unconfigured default, then configured + off, then configured + enabled.
    model.sheet = .discord;
    {
        var arena4 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena4.deinit();
        try buildAndLayout(arena4.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.discord_configured = true;
    {
        var arena4b = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena4b.deinit();
        try buildAndLayout(arena4b.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.discord_enabled = true;
    {
        var arena5 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena5.deinit();
        try buildAndLayout(arena5.allocator(), player_sheets_markup, &model, 980, 660);
    }
    model.discord_configured = false;
    model.discord_enabled = false;
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
}
