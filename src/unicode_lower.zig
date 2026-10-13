//! Unicode lowercase used by mobile's suggestion keys and festival names.
//! Ranges follow Unicode 17 default casing, including dotted I. Greek final
//! sigma is not context-mapped: a word-final Σ lowers to σ, not ς, which is
//! enough for chip text and dedup without the cased/ignorable tables.
const std = @import("std");

pub fn lower(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return text;
    const out = arena.alloc(u8, text.len * 3) catch return text;
    var written: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == 0x130) {
            const bytes = "i\xcc\x87";
            @memcpy(out[written..][0..bytes.len], bytes);
            written += bytes.len;
        } else {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(lowerScalar(cp), &bytes) catch unreachable;
            @memcpy(out[written..][0..n], bytes[0..n]);
            written += n;
        }
    }
    return out[0..written];
}

const LowerRange = struct { first: u21, last: u21, step: u2, delta: i32 };
fn lowerScalar(cp: u21) u21 {
    var lo: usize = 0;
    var hi = lower_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = lower_ranges[mid];
        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else {
            if ((cp - r.first) % r.step != 0) return cp;
            return @intCast(@as(i32, cp) + r.delta);
        }
    }
    return cp;
}

const lower_ranges = [_]LowerRange{
    .{ .first = 0x41, .last = 0x5a, .step = 1, .delta = 32 },
    .{ .first = 0xc0, .last = 0xd6, .step = 1, .delta = 32 },
    .{ .first = 0xd8, .last = 0xde, .step = 1, .delta = 32 },
    .{ .first = 0x100, .last = 0x12e, .step = 2, .delta = 1 },
    .{ .first = 0x132, .last = 0x136, .step = 2, .delta = 1 },
    .{ .first = 0x139, .last = 0x147, .step = 2, .delta = 1 },
    .{ .first = 0x14a, .last = 0x176, .step = 2, .delta = 1 },
    .{ .first = 0x178, .last = 0x178, .step = 1, .delta = -121 },
    .{ .first = 0x179, .last = 0x17d, .step = 2, .delta = 1 },
    .{ .first = 0x181, .last = 0x181, .step = 1, .delta = 210 },
    .{ .first = 0x182, .last = 0x184, .step = 2, .delta = 1 },
    .{ .first = 0x186, .last = 0x186, .step = 1, .delta = 206 },
    .{ .first = 0x187, .last = 0x187, .step = 1, .delta = 1 },
    .{ .first = 0x189, .last = 0x18a, .step = 1, .delta = 205 },
    .{ .first = 0x18b, .last = 0x18b, .step = 1, .delta = 1 },
    .{ .first = 0x18e, .last = 0x18e, .step = 1, .delta = 79 },
    .{ .first = 0x18f, .last = 0x18f, .step = 1, .delta = 202 },
    .{ .first = 0x190, .last = 0x190, .step = 1, .delta = 203 },
    .{ .first = 0x191, .last = 0x191, .step = 1, .delta = 1 },
    .{ .first = 0x193, .last = 0x193, .step = 1, .delta = 205 },
    .{ .first = 0x194, .last = 0x194, .step = 1, .delta = 207 },
    .{ .first = 0x196, .last = 0x196, .step = 1, .delta = 211 },
    .{ .first = 0x197, .last = 0x197, .step = 1, .delta = 209 },
    .{ .first = 0x198, .last = 0x198, .step = 1, .delta = 1 },
    .{ .first = 0x19c, .last = 0x19c, .step = 1, .delta = 211 },
    .{ .first = 0x19d, .last = 0x19d, .step = 1, .delta = 213 },
    .{ .first = 0x19f, .last = 0x19f, .step = 1, .delta = 214 },
    .{ .first = 0x1a0, .last = 0x1a4, .step = 2, .delta = 1 },
    .{ .first = 0x1a6, .last = 0x1a6, .step = 1, .delta = 218 },
    .{ .first = 0x1a7, .last = 0x1a7, .step = 1, .delta = 1 },
    .{ .first = 0x1a9, .last = 0x1a9, .step = 1, .delta = 218 },
    .{ .first = 0x1ac, .last = 0x1ac, .step = 1, .delta = 1 },
    .{ .first = 0x1ae, .last = 0x1ae, .step = 1, .delta = 218 },
    .{ .first = 0x1af, .last = 0x1af, .step = 1, .delta = 1 },
    .{ .first = 0x1b1, .last = 0x1b2, .step = 1, .delta = 217 },
    .{ .first = 0x1b3, .last = 0x1b5, .step = 2, .delta = 1 },
    .{ .first = 0x1b7, .last = 0x1b7, .step = 1, .delta = 219 },
    .{ .first = 0x1b8, .last = 0x1b8, .step = 1, .delta = 1 },
    .{ .first = 0x1bc, .last = 0x1bc, .step = 1, .delta = 1 },
    .{ .first = 0x1c4, .last = 0x1c4, .step = 1, .delta = 2 },
    .{ .first = 0x1c5, .last = 0x1c5, .step = 1, .delta = 1 },
    .{ .first = 0x1c7, .last = 0x1c7, .step = 1, .delta = 2 },
    .{ .first = 0x1c8, .last = 0x1c8, .step = 1, .delta = 1 },
    .{ .first = 0x1ca, .last = 0x1ca, .step = 1, .delta = 2 },
    .{ .first = 0x1cb, .last = 0x1db, .step = 2, .delta = 1 },
    .{ .first = 0x1de, .last = 0x1ee, .step = 2, .delta = 1 },
    .{ .first = 0x1f1, .last = 0x1f1, .step = 1, .delta = 2 },
    .{ .first = 0x1f2, .last = 0x1f4, .step = 2, .delta = 1 },
    .{ .first = 0x1f6, .last = 0x1f6, .step = 1, .delta = -97 },
    .{ .first = 0x1f7, .last = 0x1f7, .step = 1, .delta = -56 },
    .{ .first = 0x1f8, .last = 0x21e, .step = 2, .delta = 1 },
    .{ .first = 0x220, .last = 0x220, .step = 1, .delta = -130 },
    .{ .first = 0x222, .last = 0x232, .step = 2, .delta = 1 },
    .{ .first = 0x23a, .last = 0x23a, .step = 1, .delta = 10795 },
    .{ .first = 0x23b, .last = 0x23b, .step = 1, .delta = 1 },
    .{ .first = 0x23d, .last = 0x23d, .step = 1, .delta = -163 },
    .{ .first = 0x23e, .last = 0x23e, .step = 1, .delta = 10792 },
    .{ .first = 0x241, .last = 0x241, .step = 1, .delta = 1 },
    .{ .first = 0x243, .last = 0x243, .step = 1, .delta = -195 },
    .{ .first = 0x244, .last = 0x244, .step = 1, .delta = 69 },
    .{ .first = 0x245, .last = 0x245, .step = 1, .delta = 71 },
    .{ .first = 0x246, .last = 0x24e, .step = 2, .delta = 1 },
    .{ .first = 0x370, .last = 0x372, .step = 2, .delta = 1 },
    .{ .first = 0x376, .last = 0x376, .step = 1, .delta = 1 },
    .{ .first = 0x37f, .last = 0x37f, .step = 1, .delta = 116 },
    .{ .first = 0x386, .last = 0x386, .step = 1, .delta = 38 },
    .{ .first = 0x388, .last = 0x38a, .step = 1, .delta = 37 },
    .{ .first = 0x38c, .last = 0x38c, .step = 1, .delta = 64 },
    .{ .first = 0x38e, .last = 0x38f, .step = 1, .delta = 63 },
    .{ .first = 0x391, .last = 0x3a1, .step = 1, .delta = 32 },
    .{ .first = 0x3a3, .last = 0x3ab, .step = 1, .delta = 32 },
    .{ .first = 0x3cf, .last = 0x3cf, .step = 1, .delta = 8 },
    .{ .first = 0x3d8, .last = 0x3ee, .step = 2, .delta = 1 },
    .{ .first = 0x3f4, .last = 0x3f4, .step = 1, .delta = -60 },
    .{ .first = 0x3f7, .last = 0x3f7, .step = 1, .delta = 1 },
    .{ .first = 0x3f9, .last = 0x3f9, .step = 1, .delta = -7 },
    .{ .first = 0x3fa, .last = 0x3fa, .step = 1, .delta = 1 },
    .{ .first = 0x3fd, .last = 0x3ff, .step = 1, .delta = -130 },
    .{ .first = 0x400, .last = 0x40f, .step = 1, .delta = 80 },
    .{ .first = 0x410, .last = 0x42f, .step = 1, .delta = 32 },
    .{ .first = 0x460, .last = 0x480, .step = 2, .delta = 1 },
    .{ .first = 0x48a, .last = 0x4be, .step = 2, .delta = 1 },
    .{ .first = 0x4c0, .last = 0x4c0, .step = 1, .delta = 15 },
    .{ .first = 0x4c1, .last = 0x4cd, .step = 2, .delta = 1 },
    .{ .first = 0x4d0, .last = 0x52e, .step = 2, .delta = 1 },
    .{ .first = 0x531, .last = 0x556, .step = 1, .delta = 48 },
    .{ .first = 0x10a0, .last = 0x10c5, .step = 1, .delta = 7264 },
    .{ .first = 0x10c7, .last = 0x10c7, .step = 1, .delta = 7264 },
    .{ .first = 0x10cd, .last = 0x10cd, .step = 1, .delta = 7264 },
    .{ .first = 0x13a0, .last = 0x13ef, .step = 1, .delta = 38864 },
    .{ .first = 0x13f0, .last = 0x13f5, .step = 1, .delta = 8 },
    .{ .first = 0x1c89, .last = 0x1c89, .step = 1, .delta = 1 },
    .{ .first = 0x1c90, .last = 0x1cba, .step = 1, .delta = -3008 },
    .{ .first = 0x1cbd, .last = 0x1cbf, .step = 1, .delta = -3008 },
    .{ .first = 0x1e00, .last = 0x1e94, .step = 2, .delta = 1 },
    .{ .first = 0x1e9e, .last = 0x1e9e, .step = 1, .delta = -7615 },
    .{ .first = 0x1ea0, .last = 0x1efe, .step = 2, .delta = 1 },
    .{ .first = 0x1f08, .last = 0x1f0f, .step = 1, .delta = -8 },
    .{ .first = 0x1f18, .last = 0x1f1d, .step = 1, .delta = -8 },
    .{ .first = 0x1f28, .last = 0x1f2f, .step = 1, .delta = -8 },
    .{ .first = 0x1f38, .last = 0x1f3f, .step = 1, .delta = -8 },
    .{ .first = 0x1f48, .last = 0x1f4d, .step = 1, .delta = -8 },
    .{ .first = 0x1f59, .last = 0x1f5f, .step = 2, .delta = -8 },
    .{ .first = 0x1f68, .last = 0x1f6f, .step = 1, .delta = -8 },
    .{ .first = 0x1f88, .last = 0x1f8f, .step = 1, .delta = -8 },
    .{ .first = 0x1f98, .last = 0x1f9f, .step = 1, .delta = -8 },
    .{ .first = 0x1fa8, .last = 0x1faf, .step = 1, .delta = -8 },
    .{ .first = 0x1fb8, .last = 0x1fb9, .step = 1, .delta = -8 },
    .{ .first = 0x1fba, .last = 0x1fbb, .step = 1, .delta = -74 },
    .{ .first = 0x1fbc, .last = 0x1fbc, .step = 1, .delta = -9 },
    .{ .first = 0x1fc8, .last = 0x1fcb, .step = 1, .delta = -86 },
    .{ .first = 0x1fcc, .last = 0x1fcc, .step = 1, .delta = -9 },
    .{ .first = 0x1fd8, .last = 0x1fd9, .step = 1, .delta = -8 },
    .{ .first = 0x1fda, .last = 0x1fdb, .step = 1, .delta = -100 },
    .{ .first = 0x1fe8, .last = 0x1fe9, .step = 1, .delta = -8 },
    .{ .first = 0x1fea, .last = 0x1feb, .step = 1, .delta = -112 },
    .{ .first = 0x1fec, .last = 0x1fec, .step = 1, .delta = -7 },
    .{ .first = 0x1ff8, .last = 0x1ff9, .step = 1, .delta = -128 },
    .{ .first = 0x1ffa, .last = 0x1ffb, .step = 1, .delta = -126 },
    .{ .first = 0x1ffc, .last = 0x1ffc, .step = 1, .delta = -9 },
    .{ .first = 0x2126, .last = 0x2126, .step = 1, .delta = -7517 },
    .{ .first = 0x212a, .last = 0x212a, .step = 1, .delta = -8383 },
    .{ .first = 0x212b, .last = 0x212b, .step = 1, .delta = -8262 },
    .{ .first = 0x2132, .last = 0x2132, .step = 1, .delta = 28 },
    .{ .first = 0x2160, .last = 0x216f, .step = 1, .delta = 16 },
    .{ .first = 0x2183, .last = 0x2183, .step = 1, .delta = 1 },
    .{ .first = 0x24b6, .last = 0x24cf, .step = 1, .delta = 26 },
    .{ .first = 0x2c00, .last = 0x2c2f, .step = 1, .delta = 48 },
    .{ .first = 0x2c60, .last = 0x2c60, .step = 1, .delta = 1 },
    .{ .first = 0x2c62, .last = 0x2c62, .step = 1, .delta = -10743 },
    .{ .first = 0x2c63, .last = 0x2c63, .step = 1, .delta = -3814 },
    .{ .first = 0x2c64, .last = 0x2c64, .step = 1, .delta = -10727 },
    .{ .first = 0x2c67, .last = 0x2c6b, .step = 2, .delta = 1 },
    .{ .first = 0x2c6d, .last = 0x2c6d, .step = 1, .delta = -10780 },
    .{ .first = 0x2c6e, .last = 0x2c6e, .step = 1, .delta = -10749 },
    .{ .first = 0x2c6f, .last = 0x2c6f, .step = 1, .delta = -10783 },
    .{ .first = 0x2c70, .last = 0x2c70, .step = 1, .delta = -10782 },
    .{ .first = 0x2c72, .last = 0x2c72, .step = 1, .delta = 1 },
    .{ .first = 0x2c75, .last = 0x2c75, .step = 1, .delta = 1 },
    .{ .first = 0x2c7e, .last = 0x2c7f, .step = 1, .delta = -10815 },
    .{ .first = 0x2c80, .last = 0x2ce2, .step = 2, .delta = 1 },
    .{ .first = 0x2ceb, .last = 0x2ced, .step = 2, .delta = 1 },
    .{ .first = 0x2cf2, .last = 0x2cf2, .step = 1, .delta = 1 },
    .{ .first = 0xa640, .last = 0xa66c, .step = 2, .delta = 1 },
    .{ .first = 0xa680, .last = 0xa69a, .step = 2, .delta = 1 },
    .{ .first = 0xa722, .last = 0xa72e, .step = 2, .delta = 1 },
    .{ .first = 0xa732, .last = 0xa76e, .step = 2, .delta = 1 },
    .{ .first = 0xa779, .last = 0xa77b, .step = 2, .delta = 1 },
    .{ .first = 0xa77d, .last = 0xa77d, .step = 1, .delta = -35332 },
    .{ .first = 0xa77e, .last = 0xa786, .step = 2, .delta = 1 },
    .{ .first = 0xa78b, .last = 0xa78b, .step = 1, .delta = 1 },
    .{ .first = 0xa78d, .last = 0xa78d, .step = 1, .delta = -42280 },
    .{ .first = 0xa790, .last = 0xa792, .step = 2, .delta = 1 },
    .{ .first = 0xa796, .last = 0xa7a8, .step = 2, .delta = 1 },
    .{ .first = 0xa7aa, .last = 0xa7aa, .step = 1, .delta = -42308 },
    .{ .first = 0xa7ab, .last = 0xa7ab, .step = 1, .delta = -42319 },
    .{ .first = 0xa7ac, .last = 0xa7ac, .step = 1, .delta = -42315 },
    .{ .first = 0xa7ad, .last = 0xa7ad, .step = 1, .delta = -42305 },
    .{ .first = 0xa7ae, .last = 0xa7ae, .step = 1, .delta = -42308 },
    .{ .first = 0xa7b0, .last = 0xa7b0, .step = 1, .delta = -42258 },
    .{ .first = 0xa7b1, .last = 0xa7b1, .step = 1, .delta = -42282 },
    .{ .first = 0xa7b2, .last = 0xa7b2, .step = 1, .delta = -42261 },
    .{ .first = 0xa7b3, .last = 0xa7b3, .step = 1, .delta = 928 },
    .{ .first = 0xa7b4, .last = 0xa7c2, .step = 2, .delta = 1 },
    .{ .first = 0xa7c4, .last = 0xa7c4, .step = 1, .delta = -48 },
    .{ .first = 0xa7c5, .last = 0xa7c5, .step = 1, .delta = -42307 },
    .{ .first = 0xa7c6, .last = 0xa7c6, .step = 1, .delta = -35384 },
    .{ .first = 0xa7c7, .last = 0xa7c9, .step = 2, .delta = 1 },
    .{ .first = 0xa7cb, .last = 0xa7cb, .step = 1, .delta = -42343 },
    .{ .first = 0xa7cc, .last = 0xa7da, .step = 2, .delta = 1 },
    .{ .first = 0xa7dc, .last = 0xa7dc, .step = 1, .delta = -42561 },
    .{ .first = 0xa7f5, .last = 0xa7f5, .step = 1, .delta = 1 },
    .{ .first = 0xff21, .last = 0xff3a, .step = 1, .delta = 32 },
    .{ .first = 0x10400, .last = 0x10427, .step = 1, .delta = 40 },
    .{ .first = 0x104b0, .last = 0x104d3, .step = 1, .delta = 40 },
    .{ .first = 0x10570, .last = 0x1057a, .step = 1, .delta = 39 },
    .{ .first = 0x1057c, .last = 0x1058a, .step = 1, .delta = 39 },
    .{ .first = 0x1058c, .last = 0x10592, .step = 1, .delta = 39 },
    .{ .first = 0x10594, .last = 0x10595, .step = 1, .delta = 39 },
    .{ .first = 0x10c80, .last = 0x10cb2, .step = 1, .delta = 64 },
    .{ .first = 0x10d50, .last = 0x10d65, .step = 1, .delta = 32 },
    .{ .first = 0x118a0, .last = 0x118bf, .step = 1, .delta = 32 },
    .{ .first = 0x16e40, .last = 0x16e5f, .step = 1, .delta = 32 },
    .{ .first = 0x16ea0, .last = 0x16eb8, .step = 1, .delta = 27 },
    .{ .first = 0x1e900, .last = 0x1e921, .step = 1, .delta = 34 },
};

test "Unicode lowercase matches mobile default casing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inputs = [_][]const u8{ "DIWALI", "DÍA DE MUERTOS", "İSTANBUL", "ΟΣΑ", "ΟΣ", "𐐀", "ПРАЗДНИК" };
    const expected = [_][]const u8{ "diwali", "día de muertos", "i\xcc\x87stanbul", "οσα", "οσ", "𐐨", "праздник" };
    for (inputs, expected) |input, result| try std.testing.expectEqualStrings(result, lower(arena.allocator(), input));
}
