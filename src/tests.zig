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
    _ = @import("model.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

const onboarding_markup = @embedFile("views/onboarding.native");
const mini_markup = @embedFile("views/mini.native");
const player_top_markup = @embedFile("views/player-top.native");
const player_sidebar_markup = @embedFile("views/player-sidebar.native");
const player_panel_markup = @embedFile("views/player-panel.native");
const player_deck_markup = @embedFile("views/player-deck.native");
const player_sheets_markup = @embedFile("views/player-sheets.native");

fn buildAndLayout(arena: std.mem.Allocator, source: []const u8, model: *const Model, w: f32, h: f32) !void {
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
    inline for (.{ player_top_markup, player_sidebar_markup, player_deck_markup }) |source| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        try buildAndLayout(arena_state.allocator(), source, &model, 980, 660);
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
}

test "composed player view (Zig stage + fragments) builds and lays out" {
    const views = @import("views.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model: Model = .{};
    model.phase = .player;
    model.sidebar_open = true;
    model.active_tab = .booth;
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

test "mini view builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    model.mini_open = true;
    try buildAndLayout(arena_state.allocator(), mini_markup, &model, 420, 168);
}
