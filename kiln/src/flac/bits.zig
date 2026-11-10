// SPDX-License-Identifier: MIT
//! ビット単位の読み取り(上位ビットから)。FLAC のフレームの復号に使う。
//! データの終わりを越えて読もうとすると `EndOfData` を返す(壊れたフレームを見分けるため)。
const std = @import("std");

pub const Error = error{EndOfData};

pub const Reader = struct {
    data: []const u8,
    /// 読み取り位置(ビット)。`data.len * 8` を超えない
    pos: usize = 0,

    /// 残りのビット数
    pub fn remaining(r: *const Reader) usize {
        return r.data.len * 8 - r.pos;
    }

    /// 現在位置からの 64 ビットの窓(最上位ビットが現在位置)。少なくとも上位 57 ビットは有効で、
    /// データの終わりを越えた分は 0
    inline fn window(r: *const Reader) u64 {
        const byte = r.pos >> 3;
        var v: u64 = 0;
        if (r.data.len >= 8 and byte <= r.data.len - 8) {
            v = std.mem.readInt(u64, r.data[byte..][0..8], .big);
        } else {
            for (0..8) |i| {
                v <<= 8;
                if (byte + i < r.data.len) v |= r.data[byte + i];
            }
        }
        return v << @intCast(r.pos & 7);
    }

    /// `n` ビット(n <= 56)を符号なしで読む
    pub fn read(r: *Reader, n: u6) Error!u64 {
        std.debug.assert(n <= 56);
        if (n == 0) return 0;
        if (n > r.remaining()) return error.EndOfData;
        const v = r.window() >> @intCast(64 - @as(u7, n));
        r.pos += n;
        return v;
    }

    /// `n` ビット(1 <= n <= 56)を 2 の補数の符号付きで読む
    pub fn readSigned(r: *Reader, n: u6) Error!i64 {
        std.debug.assert(n >= 1);
        const u = try r.read(n);
        const s: u6 = @intCast(64 - @as(u7, n));
        return @as(i64, @bitCast(u << s)) >> s;
    }

    /// 1 が現れるまでの 0 の数を読む(1 も読み進める)。Rice 符号の商や、無駄ビットの数に使う
    pub fn readUnary(r: *Reader) Error!u64 {
        var zeros: u64 = 0;
        while (true) {
            const rem = r.remaining();
            if (rem == 0) return error.EndOfData;
            const valid = @min(64 - (r.pos & 7), rem);
            const lz = @clz(r.window());
            if (lz < valid) {
                r.pos += lz + 1;
                return zeros + lz;
            }
            zeros += valid;
            r.pos += valid;
        }
    }

    /// 次のバイト境界まで進める
    pub fn alignByte(r: *Reader) void {
        r.pos = (r.pos + 7) & ~@as(usize, 7);
    }
};

/// ビット単位の書き込み(上位ビットから)。`buf` は書く分より大きいこと(呼び出し側が上限を見積もる)
pub const Writer = struct {
    buf: []u8,
    /// 書き終えたバイト数
    len: usize = 0,
    acc: u64 = 0,
    /// `acc` の下位にたまっているビット数(0〜7。put の中では一時的に増える)
    nbits: u6 = 0,

    /// `v` の下位 `n` ビット(n <= 32)を書く
    pub fn put(w: *Writer, v: u64, n: u6) void {
        std.debug.assert(n <= 32);
        if (n == 0) return;
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        w.acc = (w.acc << @intCast(n)) | (v & mask);
        w.nbits += n;
        while (w.nbits >= 8) {
            w.nbits -= 8;
            w.buf[w.len] = @truncate(w.acc >> @intCast(w.nbits));
            w.len += 1;
        }
        w.acc &= (@as(u64, 1) << @intCast(w.nbits)) - 1;
    }

    /// 符号付きの `v` を `n` ビット(n <= 33)の 2 の補数で書く
    pub fn putSigned(w: *Writer, v: i64, n: u6) void {
        const u: u64 = @bitCast(v);
        if (n > 32) {
            w.put(u >> 32, n - 32);
            w.put(u, 32);
        } else w.put(u, n);
    }

    /// `zeros` 個の 0 と 1 を書く(単項符号)
    pub fn putUnary(w: *Writer, zeros: u64) void {
        var z = zeros;
        while (z >= 32) : (z -= 32) w.put(0, 32);
        w.put(1, @intCast(z + 1));
    }

    /// 次のバイト境界まで 0 で埋める
    pub fn alignByte(w: *Writer) void {
        if (w.nbits > 0) w.put(0, 8 - w.nbits);
    }

    pub fn written(w: *const Writer) []u8 {
        std.debug.assert(w.nbits == 0);
        return w.buf[0..w.len];
    }
};

test Writer {
    var buf: [16]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    w.put(0b101, 3);
    w.putSigned(-2, 2);
    w.putUnary(1);
    w.put(0xABCDEF01, 32);
    w.putSigned(-1, 33);
    w.putUnary(40);
    w.alignByte();
    var r: Reader = .{ .data = w.written() };
    try std.testing.expectEqual(0b101, try r.read(3));
    try std.testing.expectEqual(-2, try r.readSigned(2));
    try std.testing.expectEqual(1, try r.readUnary());
    try std.testing.expectEqual(0xABCDEF01, try r.read(32));
    try std.testing.expectEqual(-1, try r.readSigned(33));
    try std.testing.expectEqual(40, try r.readUnary());
}

test Reader {
    var r: Reader = .{ .data = &.{ 0b1011_0011, 0b0101_1111, 0x00, 0x01 } };
    try std.testing.expectEqual(0b101, try r.read(3));
    try std.testing.expectEqual(-2, try r.readSigned(2)); // 10
    try std.testing.expectEqual(1, try r.readUnary()); // 01
    try std.testing.expectEqual(0, try r.readUnary()); // 1
    try std.testing.expectEqual(1, try r.readUnary()); // 次のバイトの 01
    try std.testing.expectEqual(0b01_1111, try r.read(6));
    // 0x00 0x01: 1 の前に 0 が 15 個
    try std.testing.expectEqual(15, try r.readUnary());
    try std.testing.expectEqual(0, r.remaining());
    try std.testing.expectError(error.EndOfData, r.read(1));
    try std.testing.expectError(error.EndOfData, r.readUnary());

    // 0 だけが続くと EndOfData
    var z: Reader = .{ .data = &@as([20]u8, @splat(0)) };
    try std.testing.expectError(error.EndOfData, z.readUnary());

    // 長い読み取りと、窓の境目をまたぐ単項符号
    var data: [40]u8 = @splat(0);
    data[0] = 0xFF;
    data[37] = 0x80;
    var l: Reader = .{ .data = &data };
    try std.testing.expectEqual(0xFF << 25, try l.read(33));
    try std.testing.expectEqual(37 * 8 - 33, try l.readUnary());
    l.alignByte();
    try std.testing.expectEqual(38 * 8, l.pos);
    var m: Reader = .{ .data = &.{0xFF} };
    try std.testing.expectEqual(-1, try m.readSigned(8));
}
