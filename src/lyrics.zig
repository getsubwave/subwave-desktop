//! Lyrics for the track the listener is hearing: the station's answer from
//! GET /api/lyrics/current (mirrors web/components/skins/lyrics.ts in the
//! subwave monorepo). `Store` keeps one track's answer in fixed buffers,
//! `Store.moment` says where in its lines the song stands, and the rest is the
//! retry and timing arithmetic, kept pure so the suite can pin it.
const std = @import("std");
const builtin = @import("builtin");
const font_ttf = @import("native_sdk").canvas.font_ttf;
const json = @import("json.zig");
const utf8 = @import("utf8.zig");

// Only macOS draws text through the system (CoreText), which falls back to
// whatever installed font has the glyph. Windows (DirectWrite, with the SDK's
// fallback switched off) and Linux (the bundled outlines alone) draw only what
// Geist covers, so a song in Gurmukhi, Greek or Hangul is a wall of boxes there.
pub const system_fallback = builtin.os.tag == .macos;

pub const max_lines = 200;
pub const text_capacity = 12 * 1024;

// The station bounds its own per-track correction to ±30 s, and the device
// nudge shares the bound: past that it is the wrong lyric file, not timing.
pub const offset_min_ms: i64 = -30_000;
pub const offset_max_ms: i64 = 30_000;
pub const offset_nudge_ms: i64 = 100;

// A station that did not answer is asked again after 5, 10, 20 and 40 s, then
// every minute, and never sooner than its Retry-After. The SDK hands the model
// no response headers, so that is read from the 503's body, which repeats it.
const retry_base_ms: u64 = 5_000;
const retry_max_ms: u64 = 60_000;

// `pending` means the station is still asking LRCLIB about the track: ask
// again every 4 s, ten times at most, then settle for what it has.
pub const pending_recheck_ms: u64 = 4_000;
pub const pending_max_asks: u8 = 10;

// LRC times lines, not words, so a line is paced at roughly word_ms a word,
// never under the floor and never past the next line. A line left up longer
// than line_hold_ms with nothing following is an instrumental break, and the
// line after a break is teased tease_ms before it is sung.
const word_ms: i64 = 380;
const min_sung_ms: i64 = 900;
pub const line_hold_ms: i64 = 9_000;
pub const tease_ms: i64 = 3_500;

// How long the stage stays laid out for lyrics after they stop showing.
// Between two tracks that both have them the new lines take a moment to load,
// and dropping out of the lyrics layout for that moment would flick the page.
pub const layout_hold_ms: u64 = 1_500;

// The model's listener-track id buffer is this size too (asserted there): a
// shorter copy here would never equal the id it was asked about.
pub const song_capacity = 64;

pub const Status = enum {
    /// Nothing to ask about: lyrics are off, or no library track is on.
    idle,
    loading,
    ready,
    /// The station or the network did not answer; a retry is armed.
    unavailable,
    /// The operator has the Lyrics panel switched off (403).
    disabled,
    /// The track left the station's recent-play window (409), or the answer
    /// named some other track.
    gone,
    /// A private station refused the password (401). Never retried: every
    /// refusal spends the address's station-read attempts.
    locked,
};

pub const Source = enum { unknown, music_server, lrclib };

const Line = struct {
    start_ms: ?i64 = null,
    offset: u16 = 0,
    len: u16 = 0,
};

comptime {
    std.debug.assert(text_capacity <= std.math.maxInt(u16));
}

/// Where the song stands in its lines.
pub const Moment = struct {
    /// The line being sung; null in an intro, a break, or after the last line.
    current: ?usize = null,
    /// How far through `current`'s words the singing is, 0 to 1.
    progress: f32 = 0,
    /// The line to show faintly after it.
    next: ?usize = null,
    /// Nothing is being sung: an intro, an instrumental break or the outro.
    resting: bool = false,
};

/// The three lines the stage shows: the one just sung, the one being sung cut
/// around its newest lit word, and the next one waiting.
pub const Stage = struct {
    before: []const u8 = "",
    sung: []const u8 = "",
    word: []const u8 = "",
    rest: []const u8 = "",
    next: []const u8 = "",
    resting: bool = false,
};

/// An untimed line for the hand scroller; a blank one is a stanza break.
pub const Row = struct {
    text: []const u8 = "",
    blank: bool = false,
};

pub const Store = struct {
    song_buf: [song_capacity]u8 = undefined,
    song_len: usize = 0,
    status: Status = .idle,
    synced: bool = false,
    pending: bool = false,
    source: Source = .unknown,
    station_offset_ms: i64 = 0,
    lines: [max_lines]Line = undefined,
    count: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    misses: u8 = 0,
    pending_asks: u8 = 0,
    /// Whether this player can draw the lines (see `drawable`). Lines it
    /// can't stay off the stage rather than show as boxes.
    fits_font: bool = true,

    pub fn song(self: *const Store) []const u8 {
        return self.song_buf[0..self.song_len];
    }

    /// Forget the old answer and start on `song_id` ("" asks for nothing).
    pub fn begin(self: *Store, song_id: []const u8) void {
        self.* = .{};
        self.song_len = utf8.copyInto(&self.song_buf, song_id).len;
        self.status = if (self.song_len > 0) .loading else .idle;
    }

    pub fn line(self: *const Store, index: usize) []const u8 {
        const entry = self.lines[index];
        return self.text[entry.offset..][0..entry.len];
    }

    /// Synced lines, which the stage plays along with the song.
    pub fn syncedReady(self: *const Store) bool {
        return self.status == .ready and self.synced and self.count > 0 and self.fits_font;
    }

    /// Untimed lines, which the stage shows to scroll through by hand.
    pub fn plainReady(self: *const Store) bool {
        return self.status == .ready and !self.synced and self.count > 0 and self.fits_font;
    }

    /// The station's answer for this song. Returns when to ask again: while
    /// it says a better answer may be coming (`pending`), every 4 s, ten times
    /// at most; null once the answer is settled.
    pub fn accept(self: *Store, payload: json.Lyrics) ?u64 {
        if (!std.mem.eql(u8, payload.songId orelse "", self.song())) {
            self.forget(.gone);
            return null;
        }
        self.count = 0;
        self.text_len = 0;
        for (payload.lines orelse &.{}) |raw| {
            const text = raw.text orelse "";
            // A line that does not fit is dropped whole, with all after it:
            // half a line would be sung as if it were the whole one.
            if (self.count == max_lines or text.len > text_capacity - self.text_len) break;
            @memcpy(self.text[self.text_len..][0..text.len], text);
            self.lines[self.count] = .{
                .start_ms = wholeMs(raw.startMs),
                .offset = @intCast(self.text_len),
                .len = @intCast(text.len),
            };
            self.text_len += text.len;
            self.count += 1;
        }
        self.fits_font = system_fallback or drawable(self.text[0..self.text_len]);
        self.status = .ready;
        self.synced = payload.synced orelse false;
        self.station_offset_ms = offsetMs(payload.offsetMs);
        self.source = source(payload.source orelse "");
        self.pending = payload.pending orelse false;
        return self.recheck();
    }

    /// The station's reply to an ask. Returns when to ask again, or null.
    /// Switched off, gone from the air and locked are answers; only a station
    /// that did not answer (anything else) is asked again.
    pub fn reply(self: *Store, status: u16, body: []const u8) ?u64 {
        switch (status) {
            200 => {
                const parsed = json.parse(json.Lyrics, std.heap.page_allocator, body) catch return self.miss(null);
                defer parsed.deinit();
                return self.accept(parsed.value);
            },
            401 => self.forget(.locked),
            403 => self.forget(.disabled),
            409 => self.forget(.gone),
            else => return self.miss(retryAfterMs(body)),
        }
        return null;
    }

    /// The station or the network did not answer: whatever was showing goes,
    /// as on the web, and the backoff paces the next ask, never sooner than
    /// the station's Retry-After. Returns the delay before asking again.
    pub fn miss(self: *Store, retry_after_ms: ?u64) u64 {
        self.forget(.unavailable);
        const delay = retryDelayMs(self.misses, retry_after_ms);
        self.misses +|= 1;
        return delay;
    }

    /// Drop the lines and stand at `status`: a refusal asking again cannot
    /// change, or an outage.
    pub fn forget(self: *Store, status: Status) void {
        self.status = status;
        self.count = 0;
        self.text_len = 0;
        self.synced = false;
        self.pending = false;
    }

    fn recheck(self: *Store) ?u64 {
        if (!self.pending) return null;
        // Once the panel stops asking, it stops saying it is looking.
        if (self.pending_asks >= pending_max_asks) {
            self.pending = false;
            return null;
        }
        self.pending_asks += 1;
        return pending_recheck_ms;
    }

    fn startAt(self: *const Store, index: usize) ?i64 {
        return self.lines[index].start_ms;
    }

    /// What the stage shows `position_ms` into the track on the lyric clock
    /// (elapsed time plus both corrections).
    pub fn moment(self: *const Store, position_ms: i64) Moment {
        const count = if (self.synced) self.count else 0;
        var first_timed: ?usize = null;
        for (0..count) |i| {
            if (self.startAt(i) != null) {
                first_timed = i;
                break;
            }
        }
        const first = first_timed orelse return .{};

        var active: ?usize = null;
        for (0..count) |i| {
            const start = self.startAt(i) orelse continue;
            if (start > position_ms) break;
            active = i;
        }
        var following: ?usize = null;
        const from = if (active) |a| a + 1 else 0;
        for (from..count) |i| {
            if (self.startAt(i) != null) {
                following = i;
                break;
            }
        }

        const sung = active orelse return .{ .next = self.teased(first, position_ms), .resting = true };
        const start = self.startAt(sung).?;
        const next_start: ?i64 = if (following) |f| self.startAt(f).? else null;
        const gap = if (next_start) |n| n - start else std.math.maxInt(i64);
        // Past the hold with the next line still far off: a break, not a held note.
        if (position_ms - start > line_hold_ms and gap > line_hold_ms) {
            return .{ .next = if (following) |f| self.teased(f, position_ms) else null, .resting = true };
        }
        const paced = @max(@as(i64, @intCast(wordCount(self.line(sung)))) * word_ms, min_sung_ms);
        const sung_ms = @min(paced, gap);
        const progress: f32 = if (sung_ms <= 0)
            1
        else
            std.math.clamp(@as(f32, @floatFromInt(position_ms - start)) / @as(f32, @floatFromInt(sung_ms)), 0, 1);
        return .{ .current = sung, .progress = progress, .next = following };
    }

    fn teased(self: *const Store, index: usize, position_ms: i64) ?usize {
        return if (self.startAt(index).? - position_ms <= tease_ms) index else null;
    }

    /// The lines the stage shows `position_ms` into the track.
    pub fn stage(self: *const Store, position_ms: i64) Stage {
        const at = self.moment(position_ms);
        var out: Stage = .{ .resting = at.resting };
        if (at.current) |current| {
            const cut = split(self.line(current), at.progress);
            out.sung = cut.sung;
            out.word = cut.word;
            out.rest = cut.rest;
            if (current > 0) out.before = self.line(current - 1);
        }
        if (at.next) |next| out.next = self.line(next);
        return out;
    }

    /// Every line at once, for untimed lyrics. `out` holds at least `count`.
    pub fn rows(self: *const Store, out: []Row) []Row {
        for (out[0..self.count], 0..) |*row, i| {
            const text = std.mem.trim(u8, self.line(i), " \t\r\n");
            row.* = .{ .text = text, .blank = text.len == 0 };
        }
        return out[0..self.count];
    }
};

fn source(id: []const u8) Source {
    if (std.mem.eql(u8, id, "music-server")) return .music_server;
    if (std.mem.eql(u8, id, "lrclib")) return .lrclib;
    return .unknown;
}

// Station numbers are JSON numbers; anything non-finite or past what an i64
// holds is treated as absent rather than trapping the conversion.
fn wholeMs(value: ?f64) ?i64 {
    const v = value orelse return null;
    if (!std.math.isFinite(v) or v < -0x1p62 or v >= 0x1p62) return null;
    return @intFromFloat(@round(v));
}

pub fn clampOffset(ms: i64) i64 {
    return std.math.clamp(ms, offset_min_ms, offset_max_ms);
}

/// A timing correction as the station sends it or the settings file keeps it:
/// whole milliseconds within the bound, and none when it is missing or bad.
pub fn offsetMs(value: ?f64) i64 {
    return clampOffset(wholeMs(value) orelse 0);
}

/// How long to wait before asking again after the `misses`th unanswered ask
/// (0-based): the backoff, or the station's Retry-After if that is longer.
pub fn retryDelayMs(misses: u8, retry_after_ms: ?u64) u64 {
    const backoff = @min(std.math.shl(u64, retry_base_ms, @min(misses, 8)), retry_max_ms);
    return @max(backoff, @min(retry_after_ms orelse 0, retry_max_ms));
}

// The Retry-After a station's outage repeats in its body, in seconds.
fn retryAfterMs(body: []const u8) ?u64 {
    const parsed = json.parse(json.LyricsOutage, std.heap.page_allocator, body) catch return null;
    defer parsed.deinit();
    const seconds = parsed.value.retryAfter orelse return null;
    if (!std.math.isFinite(seconds) or seconds <= 0) return null;
    return @intFromFloat(@min(seconds * 1000, @as(f64, @floatFromInt(retry_max_ms))));
}

/// "0.00s", "+1.20s", "-0.10s": a device or station correction.
pub fn formatOffset(buf: []u8, ms: i64) []const u8 {
    if (ms == 0) return "0.00s";
    const magnitude = @abs(ms);
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>2}s", .{
        if (ms > 0) "+" else "-",
        magnitude / 1000,
        (magnitude % 1000) / 10,
    }) catch "";
}

/// The byte length of the whitespace at `text[i]`, 0 if there is none. The
/// set is JavaScript's `\s`, which the web splits a line's words on, so a
/// no-break or ideographic space parts words here as it does there.
fn spaceLen(text: []const u8, i: usize) usize {
    const c = text[i];
    if (c < 0x80) return if (std.ascii.isWhitespace(c)) 1 else 0;
    const len = std.unicode.utf8ByteSequenceLength(c) catch return 0;
    if (len > text.len - i) return 0;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return 0;
    return switch (cp) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => len,
        else => 0,
    };
}

fn wordEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and spaceLen(text, i) == 0) i += 1;
    return i;
}

pub fn wordCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const space = spaceLen(text, i);
        if (space > 0) {
            i += space;
            continue;
        }
        count += 1;
        i = wordEnd(text, i);
    }
    return count;
}

/// Whether the bundled face draws enough of `text` to show it: at most one
/// visible code point in ten missing, so a stray ♪ or emoji doesn't hide a
/// whole song, while a sheet in a script Geist lacks never reaches the stage.
/// Spaces, joiners and selectors draw nothing, so they don't count.
pub fn drawable(text: []const u8) bool {
    var visible: usize = 0;
    var missing: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const space = spaceLen(text, i);
        if (space > 0) {
            i += space;
            continue;
        }
        // utf8Decode takes a lone byte as its own code point, so a byte that
        // can't lead a sequence must be caught before it decodes as Latin-1.
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const decoded: ?u21 = if (len > 0 and len <= text.len - i) std.unicode.utf8Decode(text[i..][0..len]) catch null else null;
        i += if (decoded != null) len else 1;
        // A broken byte draws as a box like any other missing glyph.
        const cp = decoded orelse {
            visible += 1;
            missing += 1;
            continue;
        };
        if (cp < 0x20 or invisible(cp)) continue;
        visible += 1;
        if (font_ttf.geist_regular.glyphIndex(cp) == 0) missing += 1;
    }
    return missing * 10 <= visible;
}

fn invisible(cp: u21) bool {
    return switch (cp) {
        0x7F, 0x200B...0x200F, 0x2060...0x2064, 0xFE00...0xFE0F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

/// A sung line cut around its newest lit word: the words already sung, the
/// newest one, and those still to come. Whitespace stays with the runs, so
/// laid end to end they are the line again.
pub const Split = struct {
    sung: []const u8 = "",
    word: []const u8 = "",
    rest: []const u8 = "",
};

/// `progress` lights at least the first word, then words in step with it.
/// A line sung through has no newest word, so the accent lets go of it.
pub fn split(text: []const u8, progress: f32) Split {
    const words = wordCount(text);
    if (words == 0) return .{ .rest = text };
    const scaled: usize = @intFromFloat(@ceil(std.math.clamp(progress, 0, 1) * @as(f32, @floatFromInt(words))));
    const lit = std.math.clamp(scaled, 1, words);
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const space = spaceLen(text, i);
        if (space > 0) {
            i += space;
            continue;
        }
        const start = i;
        i = wordEnd(text, i);
        seen += 1;
        if (seen < lit) continue;
        if (progress >= 1) return .{ .sung = text[0..i], .rest = text[i..] };
        return .{ .sung = text[0..start], .word = text[start..i], .rest = text[i..] };
    }
    return .{ .sung = text };
}

/// One line for the lyrics settings on what this track has, or why nothing.
pub fn note(store: *const Store, shown: bool) []const u8 {
    if (!shown) return "Hidden on this device.";
    switch (store.status) {
        .disabled => return "The station has lyrics switched off.",
        .loading => return "Looking for lyrics…",
        .unavailable => return "The station isn’t answering. Trying again…",
        .idle => return "No lyrics right now.",
        .gone, .locked => return "No lyrics for this song.",
        .ready => {},
    }
    if (store.count > 0 and !store.fits_font) return "These lyrics are in a script this player can’t draw yet.";
    if (store.syncedReady()) {
        return if (store.source == .lrclib) "Synced lyrics, from LRCLIB." else "Synced lyrics, from the station’s library.";
    }
    if (store.plainReady()) {
        return if (store.pending)
            "Untimed for now, still looking for synced ones."
        else
            "Not timed, so they don’t follow the song. Scroll through them.";
    }
    return if (store.pending) "Looking for lyrics…" else "No lyrics for this song.";
}

const testing = std.testing;

fn parseLyrics(body: []const u8) !std.json.Parsed(json.Lyrics) {
    return json.parse(json.Lyrics, testing.allocator, body);
}

test "accept keeps the lines, the correction and the source for the song asked about" {
    var store: Store = .{};
    store.begin("s1");
    try testing.expectEqual(Status.loading, store.status);
    const parsed = try parseLyrics(
        \\{"songId":"s1","synced":true,"offsetMs":-1200,"source":"lrclib","pending":false,
        \\ "lines":[{"startMs":12500,"text":"First line"},{"startMs":15300.4,"text":"Second line"}]}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(?u64, null), store.accept(parsed.value));
    try testing.expect(store.syncedReady());
    try testing.expectEqual(@as(usize, 2), store.count);
    try testing.expectEqualStrings("Second line", store.line(1));
    try testing.expectEqual(@as(?i64, 15300), store.lines[1].start_ms);
    try testing.expectEqual(@as(i64, -1200), store.station_offset_ms);
    try testing.expectEqual(Source.lrclib, store.source);
}

test "an answer for another song is gone, never shown as this one's" {
    var store: Store = .{};
    store.begin("s1");
    const parsed = try parseLyrics(
        \\{"songId":"s0","synced":true,"offsetMs":0,"lines":[{"startMs":0,"text":"Old"}]}
    );
    defer parsed.deinit();
    _ = store.accept(parsed.value);
    try testing.expectEqual(Status.gone, store.status);
    try testing.expectEqual(@as(usize, 0), store.count);
}

test "untimed lines are plain, and a pending answer is asked again ten times" {
    var store: Store = .{};
    store.begin("s1");
    const parsed = try parseLyrics(
        \\{"songId":"s1","synced":false,"offsetMs":0,"pending":true,"source":"music-server",
        \\ "lines":[{"startMs":null,"text":"Unsung"}]}
    );
    defer parsed.deinit();
    for (0..pending_max_asks) |_| try testing.expectEqual(@as(?u64, pending_recheck_ms), store.accept(parsed.value));
    try testing.expect(store.plainReady());
    try testing.expectEqualStrings("Untimed for now, still looking for synced ones.", note(&store, true));
    // The eleventh ask settles, and the note stops saying it is looking.
    try testing.expectEqual(@as(?u64, null), store.accept(parsed.value));
    try testing.expect(!store.pending);
    try testing.expectEqualStrings("Not timed, so they don’t follow the song. Scroll through them.", note(&store, true));
}

test "an unanswered ask backs off to a minute, never sooner than Retry-After" {
    var store: Store = .{};
    store.begin("s1");
    try testing.expectEqual(@as(u64, 5_000), store.miss(null));
    try testing.expectEqual(@as(u64, 10_000), store.miss(null));
    try testing.expectEqual(@as(u64, 20_000), store.miss(null));
    try testing.expectEqual(@as(u64, 40_000), store.miss(null));
    try testing.expectEqual(@as(u64, 60_000), store.miss(null));
    try testing.expectEqual(@as(u64, 60_000), retryDelayMs(255, null));
    try testing.expectEqual(Status.unavailable, store.status);
    // The station's own window wins over a shorter backoff, up to the minute.
    try testing.expectEqual(@as(u64, 10_000), retryDelayMs(0, 10_000));
    try testing.expectEqual(@as(u64, 20_000), retryDelayMs(2, 10_000));
    try testing.expectEqual(@as(u64, 60_000), retryDelayMs(0, 600_000));
}

test "an outage while lines show takes them down, as on the web" {
    var store: Store = .{};
    store.begin("s1");
    const parsed = try parseLyrics(
        \\{"songId":"s1","synced":false,"offsetMs":0,"pending":true,"lines":[{"startMs":null,"text":"Gone"}]}
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(?u64, pending_recheck_ms), store.accept(parsed.value));
    try testing.expectEqual(@as(u64, 5_000), store.miss(null));
    try testing.expect(!store.plainReady());
    try testing.expectEqual(Status.unavailable, store.status);
    try testing.expectEqualStrings("The station isn’t answering. Trying again…", note(&store, true));
    // The next answer is shown again, and the pending budget carries on.
    try testing.expectEqual(@as(?u64, pending_recheck_ms), store.accept(parsed.value));
    try testing.expect(store.plainReady());
    try testing.expectEqual(@as(u8, 2), store.pending_asks);
}

test "reply retries only a station that did not answer" {
    var store: Store = .{};
    store.begin("s1");
    try testing.expectEqual(@as(?u64, 5_000), store.reply(503, ""));
    try testing.expectEqual(@as(?u64, 10_000), store.reply(200, "not json"));
    // The outage's body repeats Retry-After, which the backoff never undercuts.
    store.begin("s1");
    try testing.expectEqual(@as(?u64, 10_000), store.reply(503,
        \\{"error":"The music server did not answer for lyrics","retryAfter":10}
    ));
    try testing.expectEqual(@as(?u64, 10_000), store.reply(503, "{\"retryAfter\":-3}"));
    try testing.expectEqual(@as(?u64, 20_000), store.reply(502, "<html>Bad gateway</html>"));
    inline for (.{ .{ 401, Status.locked }, .{ 403, Status.disabled }, .{ 409, Status.gone } }) |case| {
        store.begin("s1");
        try testing.expectEqual(@as(?u64, null), store.reply(case[0], "{\"error\":\"no\"}"));
        try testing.expectEqual(case[1], store.status);
    }
    store.begin("s1");
    try testing.expectEqual(@as(?u64, null), store.reply(200,
        \\{"songId":"s1","synced":false,"offsetMs":0,"lines":[]}
    ));
    try testing.expectEqual(Status.ready, store.status);
    try testing.expectEqualStrings("No lyrics for this song.", note(&store, true));
}

test "lines that overflow the store are dropped whole" {
    var store: Store = .{};
    store.begin("s1");
    var lines: [max_lines + 5]json.LyricLine = undefined;
    for (&lines) |*l| l.* = .{ .startMs = 0, .text = "la" };
    _ = store.accept(.{ .songId = "s1", .synced = true, .lines = &lines });
    try testing.expectEqual(@as(usize, max_lines), store.count);

    const long = "x" ** (text_capacity - 1);
    var two = [_]json.LyricLine{ .{ .startMs = 0, .text = long }, .{ .startMs = 1, .text = "no room" } };
    _ = store.accept(.{ .songId = "s1", .synced = true, .lines = &two });
    try testing.expectEqual(@as(usize, 1), store.count);
}

fn syncedStore(store: *Store, lines: []const json.LyricLine) void {
    store.begin("s1");
    _ = store.accept(.{ .songId = "s1", .synced = true, .lines = @constCast(lines) });
}

test "moment rests through an intro and teases the first line" {
    var store: Store = .{};
    syncedStore(&store, &.{ .{ .startMs = 10_000, .text = "One two" }, .{ .startMs = 14_000, .text = "Three" } });
    const intro = store.moment(0);
    try testing.expect(intro.resting);
    try testing.expectEqual(@as(?usize, null), intro.current);
    try testing.expectEqual(@as(?usize, null), intro.next);
    const teasing = store.moment(7_000);
    try testing.expectEqual(@as(?usize, 0), teasing.next);
}

test "moment paces a line's words and hands over at the next line" {
    var store: Store = .{};
    syncedStore(&store, &.{ .{ .startMs = 1_000, .text = "one two three four" }, .{ .startMs = 5_000, .text = "next" } });
    // Four words pace at 1520 ms; halfway is two words lit.
    const half = store.moment(1_760);
    try testing.expectEqual(@as(?usize, 0), half.current);
    try testing.expectEqual(@as(?usize, 1), half.next);
    try testing.expectApproxEqAbs(@as(f32, 0.5), half.progress, 0.001);
    try testing.expectEqual(@as(f32, 1), store.moment(4_999).progress);
    try testing.expectEqual(@as(?usize, 1), store.moment(5_000).current);
}

test "moment calls a long gap a break, and the outro rests" {
    var store: Store = .{};
    syncedStore(&store, &.{ .{ .startMs = 0, .text = "Before" }, .{ .startMs = 30_000, .text = "After" } });
    try testing.expectEqual(@as(?usize, 0), store.moment(8_000).current);
    const gap = store.moment(20_000);
    try testing.expect(gap.resting);
    try testing.expectEqual(@as(?usize, null), gap.next);
    try testing.expectEqual(@as(?usize, 1), store.moment(27_000).next);
    const outro = store.moment(60_000);
    try testing.expect(outro.resting);
    try testing.expectEqual(@as(?usize, null), outro.current);
}

test "moment skips untimed lines inside synced lyrics, and ignores plain ones" {
    var store: Store = .{};
    syncedStore(&store, &.{ .{ .startMs = null, .text = "[Verse]" }, .{ .startMs = 2_000, .text = "Sung" } });
    try testing.expectEqual(@as(?usize, 1), store.moment(2_500).current);
    store.synced = false;
    try testing.expectEqual(Moment{}, store.moment(2_500));
}

test "split lights the first word at once and keeps the whitespace" {
    const text = "Hold  the line";
    const start = split(text, 0);
    try testing.expectEqualStrings("", start.sung);
    try testing.expectEqualStrings("Hold", start.word);
    try testing.expectEqualStrings("  the line", start.rest);
    const mid = split(text, 0.5);
    try testing.expectEqualStrings("Hold  ", mid.sung);
    try testing.expectEqualStrings("the", mid.word);
    try testing.expectEqualStrings(" line", mid.rest);
    try testing.expectEqualStrings("   ", split("   ", 0.5).rest);
}

test "split lets the accent go once the line is sung through" {
    const done = split("Hold the line ", 1);
    try testing.expectEqualStrings("Hold the line", done.sung);
    try testing.expectEqualStrings("", done.word);
    try testing.expectEqualStrings(" ", done.rest);
    try testing.expectEqualStrings("line", split("Hold the line", 0.99).word);
}

test "words part on the spaces the web splits on, not only ASCII ones" {
    // No-break, ideographic and narrow no-break spaces; é is not a space.
    const text = "un\u{00A0}deux\u{3000}trois\u{202F}café";
    try testing.expectEqual(@as(usize, 4), wordCount(text));
    const mid = split(text, 0.5);
    try testing.expectEqualStrings("un\u{00A0}", mid.sung);
    try testing.expectEqualStrings("deux", mid.word);
    try testing.expectEqualStrings("\u{3000}trois\u{202F}café", mid.rest);
    try testing.expectEqualStrings("café", split(text, 0.9).word);
    // A lone lead byte at the end is part of a word, never read past.
    try testing.expectEqual(@as(usize, 2), wordCount("a \xE3"));
}

test "stage cuts the sung line and names its neighbours" {
    var store: Store = .{};
    syncedStore(&store, &.{
        .{ .startMs = 0, .text = "Before it" },
        .{ .startMs = 2_000, .text = "one two three four" },
        .{ .startMs = 6_000, .text = "After it" },
    });
    const now = store.stage(2_760);
    try testing.expectEqualStrings("Before it", now.before);
    try testing.expectEqualStrings("one ", now.sung);
    try testing.expectEqualStrings("two", now.word);
    try testing.expectEqualStrings(" three four", now.rest);
    try testing.expectEqualStrings("After it", now.next);
    try testing.expect(!now.resting);
    const held = store.stage(5_000);
    try testing.expectEqualStrings("one two three four", held.sung);
    try testing.expectEqualStrings("", held.word);
    const intro: Store = .{};
    try testing.expectEqualDeep(Stage{}, intro.stage(0));
}

test "drawable tells a sheet Geist covers from one in a script it lacks" {
    try testing.expect(drawable(""));
    try testing.expect(drawable("Hold the line, café, Привет, “quoted” — and…"));
    try testing.expect(!drawable("ਇਕ ਤੇਰਾ ਪਿਆਰ ਬਾਕੀ ਦੁਨੀਆ ਬੇਕਾਰ"));
    try testing.expect(!drawable("사랑해 사랑해 oh"));
    // Instrumental markers and an emoji are a stray box, not a reason to hide.
    try testing.expect(drawable("♪Hold the line\nLove isn't always on time♪ ❤"));
    // One visible code point in ten may be missing, two may not.
    try testing.expect(drawable("♪abcdefghi"));
    try testing.expect(!drawable("♪♪abcdefgh"));
    // Spaces, joiners and variation selectors draw nothing and don't count.
    try testing.expect(drawable("a\u{200D}b\u{FE0F}\u{3000}c"));
    // Broken bytes draw as boxes.
    try testing.expect(!drawable("\xFF\xFE ok"));
}

test "a sheet this player can't draw stays off the stage, and the note says why" {
    var store: Store = .{};
    store.begin("s1");
    var lines = [_]json.LyricLine{ .{ .startMs = 0, .text = "ਇਕ ਤੇਰਾ ਪਿਆਰ" }, .{ .startMs = 4_000, .text = "ਬਾਕੀ ਦੁਨੀਆ ਬੇਕਾਰ" } };
    _ = store.accept(.{ .songId = "s1", .synced = true, .lines = &lines });
    // macOS draws through CoreText, which falls back to a font that has them.
    try testing.expectEqual(system_fallback, store.fits_font);
    try testing.expectEqual(system_fallback, store.syncedReady());
    if (!system_fallback)
        try testing.expectEqualStrings("These lyrics are in a script this player can’t draw yet.", note(&store, true));
    _ = store.accept(.{ .songId = "s1", .synced = false, .lines = &lines });
    try testing.expectEqual(system_fallback, store.plainReady());
    // The next song starts over.
    store.begin("s2");
    try testing.expect(store.fits_font);
}

test "rows lay every untimed line out, a blank one as a stanza break" {
    var store: Store = .{};
    store.begin("s1");
    var lines = [_]json.LyricLine{ .{ .text = " First \r" }, .{ .text = "  " }, .{ .text = "Second" } };
    _ = store.accept(.{ .songId = "s1", .synced = false, .lines = &lines });
    var out: [max_lines]Row = undefined;
    const rows = store.rows(&out);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("First", rows[0].text);
    try testing.expect(rows[1].blank);
    try testing.expect(!rows[2].blank);
}

test "offsets clamp to the station's bound and format with a sign" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0.00s", formatOffset(&buf, 0));
    try testing.expectEqualStrings("+1.20s", formatOffset(&buf, 1_200));
    try testing.expectEqualStrings("-0.10s", formatOffset(&buf, -100));
    try testing.expectEqual(offset_max_ms, clampOffset(90_000));
    try testing.expectEqual(offset_min_ms, clampOffset(-90_000));
}

test "the note says why there is nothing, and credits LRCLIB" {
    var store: Store = .{};
    try testing.expectEqualStrings("Hidden on this device.", note(&store, false));
    try testing.expectEqualStrings("No lyrics right now.", note(&store, true));
    store.begin("s1");
    try testing.expectEqualStrings("Looking for lyrics…", note(&store, true));
    store.forget(.disabled);
    try testing.expectEqualStrings("The station has lyrics switched off.", note(&store, true));
    syncedStore(&store, &.{.{ .startMs = 0, .text = "a" }});
    try testing.expectEqualStrings("Synced lyrics, from the station’s library.", note(&store, true));
    store.source = .lrclib;
    try testing.expectEqualStrings("Synced lyrics, from LRCLIB.", note(&store, true));
}
