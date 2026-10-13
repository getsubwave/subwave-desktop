//! Bounded live-status cache. Slots retain their URL until a fetch settles,
//! so a cancelled response cannot describe a newly assigned station.
const std = @import("std");

pub const capacity = 17; // featured + eight recents + eight directory rows
pub const concurrency = 3; // leave the SDK's 16 effect slots for the player
pub const interval_ms = 30_000;

pub const Entry = struct {
    url_store: [256]u8 = undefined,
    url_len: usize = 0,
    label_store: [256]u8 = undefined,
    label_len: usize = 0,
    online: bool = false,
    wanted: bool = false,
    waiting: bool = false,
    pending: bool = false,

    pub fn url(self: *const Entry) []const u8 {
        return self.url_store[0..self.url_len];
    }
    pub fn label(self: *const Entry) []const u8 {
        return self.label_store[0..self.label_len];
    }
    pub fn setStatus(self: *Entry, online: bool, artist: []const u8, title: []const u8) void {
        self.online = online;
        var w = std.Io.Writer.fixed(&self.label_store);
        if (!online) {
            w.writeAll("offline") catch {};
        } else {
            w.writeAll("on air") catch {};
            if (artist.len > 0 or title.len > 0) w.writeAll(" · ") catch {};
            w.writeAll(artist) catch {};
            if (artist.len > 0 and title.len > 0) w.writeAll(" — ") catch {};
            w.writeAll(title) catch {};
        }
        self.label_len = utf8End(w.buffered());
    }
};

pub const Cache = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    enabled: bool = false,
    cursor: usize = 0,

    pub fn begin(self: *Cache) void {
        for (&self.entries) |*entry| {
            entry.wanted = false;
            entry.waiting = false;
        }
    }
    pub fn want(self: *Cache, raw_url: []const u8) void {
        const url = std.mem.trimEnd(u8, raw_url, "/");
        if (url.len == 0 or url.len > 256) return;
        for (&self.entries) |*entry| {
            if (std.mem.eql(u8, url, entry.url())) {
                entry.wanted = true;
                entry.waiting = !entry.pending;
                return;
            }
        }
        for (&self.entries) |*entry| {
            if (entry.wanted or entry.pending) continue;
            entry.* = .{ .url_len = url.len, .wanted = true, .waiting = true };
            @memcpy(entry.url_store[0..url.len], url);
            return;
        }
    }
    pub fn refresh(self: *Cache) void {
        for (&self.entries) |*entry| if (entry.wanted and !entry.pending) {
            entry.waiting = true;
        };
    }
    pub fn next(self: *Cache) ?usize {
        if (!self.enabled) return null;
        var pending: usize = 0;
        for (self.entries) |entry| if (entry.pending) {
            pending += 1;
        };
        if (pending >= concurrency) return null;
        for (0..capacity) |offset| {
            const i = (self.cursor + offset) % capacity;
            const entry = &self.entries[i];
            if (!entry.wanted or !entry.waiting or entry.pending) continue;
            entry.waiting = false;
            entry.pending = true;
            self.cursor = (i + 1) % capacity;
            return i;
        }
        return null;
    }
    pub fn find(self: *const Cache, raw_url: []const u8) ?*const Entry {
        const url = std.mem.trimEnd(u8, raw_url, "/");
        for (&self.entries) |*entry| if (std.mem.eql(u8, url, entry.url())) return entry;
        return null;
    }
};

fn utf8End(bytes: []const u8) usize {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    return end;
}

test "live labels match mobile, including missing artist or title" {
    var e: Entry = .{};
    e.setStatus(true, "Björk", "Jóga");
    try std.testing.expectEqualStrings("on air · Björk — Jóga", e.label());
    e.setStatus(true, "", "Jóga");
    try std.testing.expectEqualStrings("on air · Jóga", e.label());
    e.setStatus(true, "Björk", "");
    try std.testing.expectEqualStrings("on air · Björk", e.label());
    e.setStatus(true, "", "");
    try std.testing.expectEqualStrings("on air", e.label());
    e.setStatus(false, "Björk", "Jóga");
    try std.testing.expectEqualStrings("offline", e.label());
    e.setStatus(true, "", "é" ** 256);
    try std.testing.expect(std.unicode.utf8ValidateSlice(e.label()));
}

test "cache deduplicates stations and limits concurrent probes" {
    var cache: Cache = .{ .enabled = true };
    cache.want("https://one.test/");
    cache.want("https://one.test");
    cache.want("https://two.test");
    cache.want("https://three.test");
    cache.want("https://four.test");
    const first = cache.next().?;
    try std.testing.expectEqualStrings("https://one.test", cache.entries[first].url());
    _ = cache.next().?;
    _ = cache.next().?;
    try std.testing.expect(cache.next() == null);
    cache.entries[first].pending = false;
    const fourth = cache.next().?;
    try std.testing.expectEqualStrings("https://four.test", cache.entries[fourth].url());
    cache.enabled = false;
    cache.refresh();
    try std.testing.expect(cache.next() == null);
}

test "list replacement retains outstanding URLs until their terminal response" {
    var cache: Cache = .{ .enabled = true };
    cache.want("https://old.test");
    const old = cache.next().?;
    cache.begin();
    cache.want("https://new.test");
    try std.testing.expectEqualStrings("https://old.test", cache.entries[old].url());
    try std.testing.expect(!cache.entries[old].wanted);
    try std.testing.expect(cache.find("https://new.test") != null);
    cache.entries[old].pending = false;
    cache.begin();
    cache.want("https://third.test");
    try std.testing.expectEqualStrings("https://third.test", cache.entries[old].url());
}

test "cache bounds the total stations" {
    var cache: Cache = .{};
    for (0..capacity + 3) |i| {
        var url: [64]u8 = undefined;
        cache.want(try std.fmt.bufPrint(&url, "https://station{d}.test", .{i}));
    }
    var count: usize = 0;
    for (cache.entries) |entry| if (entry.wanted) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, capacity), count);
}

test "a refresh during a slow batch does not starve later rows" {
    var cache: Cache = .{ .enabled = true };
    for (0..7) |i| {
        var url: [64]u8 = undefined;
        cache.want(try std.fmt.bufPrint(&url, "https://station{d}.test", .{i}));
    }
    const first = cache.next().?;
    _ = cache.next().?;
    _ = cache.next().?;
    cache.entries[first].pending = false;
    cache.refresh();
    try std.testing.expectEqualStrings("https://station3.test", cache.entries[cache.next().?].url());
}
