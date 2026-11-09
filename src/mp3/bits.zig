// SPDX-License-Identifier: MIT
//! ビット単位の読み取り(上位ビットから)。データの終わりを越えた分は 0 として読む。
const std = @import("std");

pub const Reader = struct {
    data: []const u8,
    /// 読み取り位置(ビット)
    pos: usize = 0,

    /// 先頭の `n` ビット(n <= 24)を読み進めずに返す
    pub fn peek(r: *const Reader, n: u5) u32 {
        if (n == 0) return 0;
        std.debug.assert(n <= 24);
        const byte = r.pos / 8;
        var v: u32 = 0;
        for (0..4) |i| {
            const b: u32 = if (byte + i < r.data.len) r.data[byte + i] else 0;
            v = (v << 8) | b;
        }
        v <<= @intCast(r.pos % 8);
        return v >> @intCast(32 - @as(u6, n));
    }

    pub fn skip(r: *Reader, n: usize) void {
        r.pos += n;
    }

    /// `n` ビット(n <= 24)を読む
    pub fn read(r: *Reader, n: u5) u32 {
        const v = r.peek(n);
        r.pos += n;
        return v;
    }

    pub fn readBool(r: *Reader) bool {
        return r.read(1) == 1;
    }
};

test Reader {
    var r: Reader = .{ .data = &.{ 0b1011_0011, 0b0101_1111 } };
    try std.testing.expectEqual(0b101, r.read(3));
    try std.testing.expectEqual(0b10011010, r.peek(8));
    try std.testing.expectEqual(0b1, r.read(1));
    try std.testing.expectEqual(0b0011_0101, r.read(8));
    // 終わりを越えた分は 0
    try std.testing.expectEqual(0b1111_0000, r.read(8));
    try std.testing.expectEqual(20, r.pos);
}
