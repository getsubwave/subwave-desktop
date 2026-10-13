//! Request prompts derived from the same context as the mobile drawer.
const std = @import("std");
const unicode_lower = @import("unicode_lower.zig");

pub const Chip = struct { t: []const u8, a: []const u8 };
pub const Context = struct {
    artist: []const u8 = "",
    festival: []const u8 = "",
    vibe: []const u8 = "",
    show: []const u8 = "",
    weather: []const u8 = "",
};

pub fn build(arena: std.mem.Allocator, ctx: Context) []const Chip {
    const out = arena.alloc(Chip, 5) catch return &.{};
    var count: usize = 0;
    if (ctx.artist.len > 0) push(arena, out, &count, "more like this", std.fmt.allocPrint(arena, "more {s}", .{ctx.artist}) catch "more like this");
    if (ctx.festival.len > 0) {
        const lower = unicode_lower.lower(arena, ctx.festival);
        push(arena, out, &count, std.fmt.allocPrint(arena, "{s} mood", .{lower}) catch "", "festival");
    }
    const vibe = if (ctx.vibe.len > 0) ctx.vibe else ctx.show;
    if (vibe.len > 0) push(arena, out, &count, std.fmt.allocPrint(arena, "{s} vibes", .{vibe}) catch "", "right now");
    if (ctx.weather.len > 0 and !std.mem.eql(u8, ctx.weather, "unknown"))
        push(arena, out, &count, weatherPhrase(arena, ctx.weather), "weather");
    push(arena, out, &count, "surprise me", "random");
    return out[0..count];
}

fn push(arena: std.mem.Allocator, out: []Chip, count: *usize, text: []const u8, attribution: []const u8) void {
    if (text.len == 0 or count.* == out.len) return;
    const key = unicode_lower.lower(arena, text);
    for (out[0..count.*]) |chip| if (std.mem.eql(u8, unicode_lower.lower(arena, chip.t), key)) return;
    out[count.*] = .{ .t = text, .a = attribution };
    count.* += 1;
}

fn weatherPhrase(arena: std.mem.Allocator, condition: []const u8) []const u8 {
    const mappings = .{
        .{ "clear", "sunny afternoon" },     .{ "sunny", "sunny afternoon" },
        .{ "cloudy", "overcast mood" },      .{ "rain", "rainy day" },
        .{ "rainy", "rainy day" },           .{ "drizzle", "rainy day" },
        .{ "snow", "snowy night" },          .{ "snowy", "snowy night" },
        .{ "fog", "foggy morning" },         .{ "foggy", "foggy morning" },
        .{ "thunderstorm", "stormy night" },
    };
    inline for (mappings) |pair| if (std.mem.eql(u8, condition, pair[0])) return pair[1];
    return std.fmt.allocPrint(arena, "{s} day", .{condition}) catch "";
}

test "suggestions match mobile order and attributions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const chips = build(arena.allocator(), .{ .artist = "Björk", .festival = "Diwali", .vibe = "slow burn", .show = "Night Shift", .weather = "rain" });
    try std.testing.expectEqual(@as(usize, 5), chips.len);
    for (chips, [_][]const u8{ "more like this", "diwali mood", "slow burn vibes", "rainy day", "surprise me" }) |chip, expected|
        try std.testing.expectEqualStrings(expected, chip.t);
    try std.testing.expectEqualStrings("more Björk", chips[0].a);
    try std.testing.expectEqualStrings("festival", chips[1].a);
    try std.testing.expectEqualStrings("right now", chips[2].a);
    try std.testing.expectEqualStrings("weather", chips[3].a);
    try std.testing.expectEqualStrings("random", chips[4].a);
}

test "missing context, show fallback, unknown weather and deduplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), build(a, .{ .weather = "unknown" }).len);
    const chips = build(a, .{ .show = "Night Shift", .weather = "windy" });
    try std.testing.expectEqualStrings("Night Shift vibes", chips[0].t);
    try std.testing.expectEqualStrings("windy day", chips[1].t);
    const dedup = build(a, .{ .festival = "OVERCAST", .weather = "cloudy" });
    try std.testing.expectEqual(@as(usize, 2), dedup.len);
    try std.testing.expectEqualStrings("festival", dedup[0].a);
}

test "all mobile weather aliases and case-sensitive fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conditions = [_][]const u8{ "clear", "sunny", "cloudy", "rain", "rainy", "drizzle", "snow", "snowy", "fog", "foggy", "thunderstorm", "Rain" };
    const phrases = [_][]const u8{ "sunny afternoon", "sunny afternoon", "overcast mood", "rainy day", "rainy day", "rainy day", "snowy night", "snowy night", "foggy morning", "foggy morning", "stormy night", "Rain day" };
    for (conditions, phrases) |condition, phrase| try std.testing.expectEqualStrings(phrase, build(arena.allocator(), .{ .weather = condition })[0].t);
}
