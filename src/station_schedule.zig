//! Fixed station persona catalogue, shared by slots and the ON NOW card.
const std = @import("std");
const utf8 = @import("utf8.zig");
const json = @import("json.zig");
pub const max_personas = 32;

pub const Persona = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    tagline: []const u8 = "",
    soul: []const u8 = "",
    avatar: []const u8 = "",
};

pub const Roster = struct {
    id_store: [max_personas][128]u8 = undefined,
    name_store: [max_personas][96]u8 = undefined,
    tagline_store: [max_personas][512]u8 = undefined,
    soul_store: [max_personas][8192]u8 = undefined,
    avatar_store: [max_personas][256]u8 = undefined,
    rows: [max_personas]Persona = [_]Persona{.{}} ** max_personas,
    count: usize = 0,

    pub fn apply(self: *Roster, personas: []const json.SchedPersona, souls_published: bool) void {
        self.count = 0;
        for (personas) |p| {
            const id = p.id orelse continue;
            if (self.count == max_personas) break;
            const i = self.count;
            self.rows[i] = .{
                .id = copy(&self.id_store[i], id),
                .name = copy(&self.name_store[i], p.name orelse ""),
                .tagline = copy(&self.tagline_store[i], p.tagline orelse ""),
                .soul = copy(&self.soul_store[i], if (souls_published) p.soul orelse "" else ""),
                .avatar = copy(&self.avatar_store[i], p.avatar orelse ""),
            };
            self.count += 1;
        }
    }

    pub fn find(self: *const Roster, id: []const u8) ?usize {
        if (id.len == 0) return null;
        for (self.rows[0..self.count], 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) return i;
        }
        return null;
    }

    pub fn guests(self: *const Roster, buf: []u8, ids: []const []const u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        var count: usize = 0;
        for (ids) |id| {
            const p = self.rows[self.find(id) orelse continue];
            if (p.name.len == 0) continue;
            w.print("{s}{s}", .{ if (count > 0) @as([]const u8, " & ") else "", p.name }) catch break;
            count += 1;
        }
        return w.buffered();
    }
};

fn copy(buf: []u8, raw: []const u8) []const u8 {
    return utf8.copyInto(buf, std.mem.trim(u8, raw, " \t\r\n"));
}

test "roster copies public blurbs, gates souls and resolves guests" {
    var roster: Roster = .{};
    const personas = [_]json.SchedPersona{
        .{ .id = "host", .name = "Heer", .tagline = "  After dark  ", .soul = "Private prompt", .avatar = "/persona-avatar/host" },
        .{ .id = "guest", .name = "Sol" },
    };
    roster.apply(&personas, false);
    try std.testing.expectEqualStrings("After dark", roster.rows[0].tagline);
    try std.testing.expectEqualStrings("", roster.rows[0].soul);
    try std.testing.expectEqualStrings("/persona-avatar/host", roster.rows[0].avatar);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Sol & Heer", roster.guests(&buf, &.{ "guest", "gone", "host" }));
    roster.apply(&personas, true);
    try std.testing.expectEqualStrings("Private prompt", roster.rows[0].soul);
    roster.apply(&.{}, true);
    try std.testing.expectEqual(@as(?usize, null), roster.find("host"));
}
