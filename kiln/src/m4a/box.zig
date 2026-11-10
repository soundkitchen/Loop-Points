// SPDX-License-Identifier: MIT
//! MP4(ISO/IEC 14496-12)のボックスの読み取り。
const std = @import("std");

pub const Error = error{InvalidM4a};

pub const Box = struct {
    kind: [4]u8,
    body: []const u8,

    pub fn is(b: Box, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &b.kind, kind);
    }
};

/// `data` に並んだボックスを順に返す
pub const Iterator = struct {
    data: []const u8,
    pos: usize = 0,

    /// 次のボックス。ボックスが `data` の外まで続くなど、長さが壊れていたら InvalidM4a
    pub fn next(it: *Iterator) Error!?Box {
        if (it.pos == it.data.len) return null;
        const rest = it.data[it.pos..];
        if (rest.len < 8) return error.InvalidM4a;
        var size: u64 = std.mem.readInt(u32, rest[0..4], .big);
        var header: usize = 8;
        if (size == 1) {
            if (rest.len < 16) return error.InvalidM4a;
            size = std.mem.readInt(u64, rest[8..16], .big);
            header = 16;
        } else if (size == 0) {
            // 最後まで続く
            size = rest.len;
        }
        if (size < header or size > rest.len) return error.InvalidM4a;
        const n: usize = @intCast(size);
        it.pos += n;
        return .{ .kind = rest[4..8].*, .body = rest[header..n] };
    }

    /// 種類が `kind` の最初のボックス
    pub fn find(data: []const u8, kind: *const [4]u8) Error!?Box {
        var it: Iterator = .{ .data = data };
        while (try it.next()) |b| if (b.is(kind)) return b;
        return null;
    }
};

/// `path` をたどって入れ子のボックスを探す(例: `.{ "mdia", "minf", "stbl" }`)
pub fn findPath(data: []const u8, comptime path: []const *const [4]u8) Error!?Box {
    var cur = data;
    var found: ?Box = null;
    inline for (path) |kind| {
        found = try Iterator.find(cur, kind) orelse return null;
        cur = found.?.body;
    }
    return found;
}

/// big endian の整数を読む。足りなければ InvalidM4a
pub fn int(comptime T: type, data: []const u8, at: usize) Error!T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    if (data.len < at or data.len - at < n) return error.InvalidM4a;
    return std.mem.readInt(T, data[at..][0..n], .big);
}

test Iterator {
    const data = "\x00\x00\x00\x0Cabcd1234" ++ "\x00\x00\x00\x01wxyz\x00\x00\x00\x00\x00\x00\x00\x11!" ++ "\x00\x00\x00\x00tail..";
    var it: Iterator = .{ .data = data };
    const a = (try it.next()).?;
    try std.testing.expect(a.is("abcd"));
    try std.testing.expectEqualStrings("1234", a.body);
    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("!", b.body);
    const c = (try it.next()).?;
    try std.testing.expectEqualStrings("..", c.body);
    try std.testing.expectEqual(null, try it.next());
    var bad: Iterator = .{ .data = "\x00\x00\x00\x20abcd" };
    try std.testing.expectError(error.InvalidM4a, bad.next());
}
