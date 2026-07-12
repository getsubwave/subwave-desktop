const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

// Pull the pure modules' unit tests into the suite.
comptime {
    _ = @import("color.zig");
    _ = @import("spectrum.zig");
}

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

const card_markup = @embedFile("skins/card.native");
const deck_markup = @embedFile("skins/deck.native");

fn buildAndLayout(arena: std.mem.Allocator, source: []const u8, model: *const Model) !void {
    var view = try AppMarkup.init(arena, source);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("markup {d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    const tree = try ui.finalize(node);
    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 620, 400), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

// Both skins must bind cleanly to the Model and lay out — a field drift becomes
// a build error here (and, via CompiledMarkupView in skins.zig, at app build).
test "card skin builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model: Model = .{};
    try buildAndLayout(arena_state.allocator(), card_markup, &model);
}

test "deck skin builds and lays out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model: Model = .{};
    model.skin = .deck;
    try buildAndLayout(arena_state.allocator(), deck_markup, &model);
}
