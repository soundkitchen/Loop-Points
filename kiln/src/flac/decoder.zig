// SPDX-License-Identifier: MIT
//! FLAC のフレームの復号(サブフレーム、残差、予測、ステレオの相関除去。RFC 9639 §9.2〜9.3)。
//!
//! 壊れた入力で整数があふれないよう、予測で求めた値がサブフレームのビット数に収まるかを
//! 1 サンプルごとに確かめる(正しいストリームでは必ず収まる)。
const std = @import("std");
const frame = @import("frame.zig");
const Header = frame.Header;
const Reader = @import("bits.zig").Reader;

pub const Error = error{
    /// フレームが壊れている(予約値、データの不足、値の範囲外、長さの食い違いなど)
    InvalidFrame,
    OutOfMemory,
};

/// 復号する(または読み飛ばす)サブフレームの出力先。null なら構造だけを読む
const Out = ?[]i64;

/// 1 サブフレームを読む。`bps` はサブフレームのビット数(side チャンネルは +1 で、最大 33)
fn subframe(r: *Reader, block_size: u32, bps: u6, out: Out) !void {
    if (try r.read(1) != 0) return error.InvalidFrame;
    const kind = try r.read(6);
    var wasted: u6 = 0;
    if (try r.read(1) == 1) {
        const k = try r.readUnary() + 1;
        if (k >= bps) return error.InvalidFrame;
        wasted = @intCast(k);
    }
    const b = bps - wasted;
    switch (kind) {
        0 => {
            const v = try r.readSigned(b);
            if (out) |o| @memset(o, v);
        },
        1 => {
            for (0..block_size) |i| {
                const v = try r.readSigned(b);
                if (out) |o| o[i] = v;
            }
        },
        8...12 => {
            const order: u32 = @intCast(kind - 8);
            try warmup(r, block_size, order, b, out);
            try residual(r, block_size, order, if (out) |o| o[order..] else null);
            if (out) |o| try predictFixed(o, order, b);
        },
        32...63 => {
            const order: u32 = @intCast(kind - 31);
            try warmup(r, block_size, order, b, out);
            const precision = try r.read(4) + 1;
            if (precision == 16) return error.InvalidFrame;
            const shift = try r.readSigned(5);
            if (shift < 0) return error.InvalidFrame;
            var coefs: [32]i64 = undefined;
            for (coefs[0..order]) |*c| c.* = try r.readSigned(@intCast(precision));
            try residual(r, block_size, order, if (out) |o| o[order..] else null);
            if (out) |o| try predictLpc(o, coefs[0..order], @intCast(shift), b);
        },
        else => return error.InvalidFrame,
    }
    if (wasted > 0) if (out) |o| {
        for (o) |*v| v.* <<= wasted;
    };
}

fn warmup(r: *Reader, block_size: u32, order: u32, b: u6, out: Out) !void {
    if (order > block_size) return error.InvalidFrame;
    for (0..order) |i| {
        const v = try r.readSigned(b);
        if (out) |o| o[i] = v;
    }
}

/// 残差(RFC 9639 §9.2.7)を読む。`out` の長さは block_size - order
fn residual(r: *Reader, block_size: u32, order: u32, out: Out) !void {
    const method = try r.read(2);
    if (method > 1) return error.InvalidFrame;
    const param_bits: u6 = if (method == 0) 4 else 5;
    const escape: u64 = if (method == 0) 15 else 31;
    const porder: u5 = @intCast(try r.read(4));
    const per = block_size >> porder;
    // ブロック長は分割数で割り切れ、最初の分割に予測の次数ぶんのサンプルが入りきること
    if (per << porder != block_size or per < order) return error.InvalidFrame;

    var i: usize = 0;
    for (0..@as(usize, 1) << porder) |p| {
        const n = if (p == 0) per - order else per;
        const k = try r.read(param_bits);
        if (k == escape) {
            const nb: u6 = @intCast(try r.read(5));
            for (0..n) |j| {
                const v: i64 = if (nb == 0) 0 else try r.readSigned(nb);
                if (out) |o| o[i + j] = v;
            }
        } else {
            const kk: u6 = @intCast(k);
            // 残差は 32 ビットの符号付き整数に収まる(RFC 9639 §9.2.7)。商がそれを超えるなら壊れている
            const max_q = (@as(u64, 1) << 32) >> kk;
            for (0..n) |j| {
                const q = try r.readUnary();
                if (q > max_q) return error.InvalidFrame;
                const u = (q << kk) | try r.read(kk);
                const v: i64 = @as(i64, @intCast(u >> 1)) ^ -@as(i64, @intCast(u & 1));
                if (out) |o| o[i + j] = v;
            }
        }
        i += n;
    }
}

/// `v` が `b` ビットの符号付き整数に収まるか
inline fn fits(v: i64, b: u6) bool {
    const lim = @as(i64, 1) << (b - 1);
    return v >= -lim and v < lim;
}

/// 固定予測(RFC 9639 §9.2.5)。`o[order..]` の残差を復号したサンプルに置き換える
fn predictFixed(o: []i64, order: u32, b: u6) !void {
    for (order..o.len) |i| {
        const p: i64 = switch (order) {
            0 => 0,
            1 => o[i - 1],
            2 => 2 * o[i - 1] - o[i - 2],
            3 => 3 * o[i - 1] - 3 * o[i - 2] + o[i - 3],
            4 => 4 * o[i - 1] - 6 * o[i - 2] + 4 * o[i - 3] - o[i - 4],
            else => unreachable,
        };
        const v = o[i] + p;
        if (!fits(v, b)) return error.InvalidFrame;
        o[i] = v;
    }
}

/// 線形予測(RFC 9639 §9.2.6)。`o[coefs.len..]` の残差を復号したサンプルに置き換える
fn predictLpc(o: []i64, coefs: []const i64, shift: u6, b: u6) !void {
    const order = coefs.len;
    for (order..o.len) |i| {
        var sum: i64 = 0;
        for (coefs, 1..) |c, j| sum += c * o[i - j];
        const v = o[i] + (sum >> shift);
        if (!fits(v, b)) return error.InvalidFrame;
        o[i] = v;
    }
}

/// サブフレームを読み終えた位置(バイト境界にそろえ、CRC-16 の 2 バイトを足したもの)が
/// フレームの終わり。`bits` は STREAMINFO で補ったビット深度
fn readSubframes(r: *Reader, h: Header, bits: u8, samples: ?[]i64) !void {
    const bs = h.block_size;
    for (0..h.channels) |ch| {
        const side = switch (h.assignment) {
            .independent => false,
            .left_side, .mid_side => ch == 1,
            .side_right => ch == 0,
        };
        const bps: u6 = @intCast(bits + @intFromBool(side));
        try subframe(r, bs, bps, if (samples) |s| s[ch * bs ..][0..bs] else null);
    }
    r.alignByte();
}

/// フレームの構造だけを読み、フレームのバイト数(CRC-16 を含む)を返す。
/// `bytes` はフレームの先頭から(終わりは分からなくてよい)
pub fn frameLen(bytes: []const u8, h: Header, bits: u8) ?usize {
    var r: Reader = .{ .data = bytes, .pos = h.len * 8 };
    readSubframes(&r, h, bits, null) catch return null;
    const end = r.pos / 8 + 2;
    return if (end <= bytes.len) end else null;
}

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    /// 復号したサンプル(チャンネルごとに block_size 個ずつ)
    buf: []i64 = &.{},

    pub fn init(gpa: std.mem.Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(d: *Decoder) void {
        d.gpa.free(d.buf);
    }

    /// フレーム `bytes`(ちょうど 1 フレーム。CRC-16 は呼び出し側が確かめる)を復号し、チャンネルごとの
    /// サンプルを返す(`[ch * block_size ..][0..block_size]`)。値は `bits` ビットの符号付き整数に収まる
    pub fn decodeFrame(d: *Decoder, bytes: []const u8, h: Header, bits: u8) Error![]const i64 {
        const n = @as(usize, h.block_size) * h.channels;
        if (d.buf.len < n) {
            d.gpa.free(d.buf);
            d.buf = &.{};
            d.buf = try d.gpa.alloc(i64, n);
        }
        const s = d.buf[0..n];
        var r: Reader = .{ .data = bytes, .pos = h.len * 8 };
        readSubframes(&r, h, bits, s) catch return error.InvalidFrame;
        if (r.pos / 8 + 2 != bytes.len) return error.InvalidFrame;

        // ステレオの相関除去
        const bs = h.block_size;
        if (h.assignment != .independent) {
            const a = s[0..bs];
            const b = s[bs..][0..bs];
            switch (h.assignment) {
                .left_side => for (a, b) |l, *x| {
                    x.* = l - x.*;
                },
                .side_right => for (a, b) |*x, rr| {
                    x.* = x.* + rr;
                },
                .mid_side => for (a, b) |*m, *x| {
                    const mid = (m.* << 1) | (x.* & 1);
                    const side = x.*;
                    m.* = (mid + side) >> 1;
                    x.* = (mid - side) >> 1;
                },
                .independent => unreachable,
            }
        }
        for (s) |v| if (!fits(v, @intCast(bits))) return error.InvalidFrame;
        return s;
    }
};

test "residual: Rice 符号と escape" {
    // method 0、分割の次数 0、パラメータ 2: 値 0, -1, 3 → zigzag 0, 1, 6
    // 0 → q=0 "1" "00"; 1 → q=0 "1" "01"; 6 → q=1 "01" "10"
    // ビット列: 00 0000 0010 1001 101 10 + 埋め
    var data: [4]u8 = undefined;
    var w: u32 = 0;
    var nbits: u5 = 0;
    const fields = [_][2]u32{ .{ 0, 2 }, .{ 0, 4 }, .{ 2, 4 }, .{ 0b100, 3 }, .{ 0b101, 3 }, .{ 0b0110, 4 } };
    for (fields) |f| {
        w = (w << @intCast(f[1])) | f[0];
        nbits += @intCast(f[1]);
    }
    std.mem.writeInt(u32, &data, w << @intCast(32 - @as(u6, nbits)), .big);
    var out: [3]i64 = undefined;
    var r: Reader = .{ .data = &data };
    try residual(&r, 3, 0, &out);
    try std.testing.expectEqualSlices(i64, &.{ 0, -1, 3 }, &out);
    try std.testing.expectEqual(nbits, r.pos);

    // 分割数で割り切れないブロック長、最初の分割に予測の次数が入りきらない
    var bad: Reader = .{ .data = &.{ 0b00_0001_00, 0 } };
    try std.testing.expectError(error.InvalidFrame, residual(&bad, 3, 0, null));
    bad = .{ .data = &.{ 0b00_0001_00, 0 } };
    try std.testing.expectError(error.InvalidFrame, residual(&bad, 4, 3, null));
}

test "predictFixed / predictLpc" {
    // 次数 2 の固定予測: 等差数列は残差 0
    var o = [_]i64{ 1, 3, 0, 0, 0 };
    try predictFixed(&o, 2, 16);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3, 5, 7, 9 }, &o);
    // 範囲外になる値は InvalidFrame
    var big = [_]i64{ 30000, 32000, 0 };
    try std.testing.expectError(error.InvalidFrame, predictFixed(&big, 2, 16));
    // LPC: s[n] = (2 * s[n-1] * 2 - 2 * s[n-2]) >> 1 = 2 s[n-1] - s[n-2]
    var l = [_]i64{ 1, 3, 0, 1 };
    try predictLpc(&l, &.{ 4, -2 }, 1, 16);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3, 5, 8 }, &l);
}

/// テスト用: 上位ビットから詰めるビットの書き込み
const TestBits = struct {
    buf: [64]u8 = @splat(0),
    pos: usize = 0,

    fn put(w: *TestBits, v: u64, n: u6) void {
        for (0..n) |i| {
            const bit: u8 = @intCast((v >> @intCast(n - 1 - i)) & 1);
            w.buf[w.pos / 8] |= bit << @intCast(7 - w.pos % 8);
            w.pos += 1;
        }
    }
};

test "Decoder: 定数・無圧縮のサブフレーム、無駄ビット、left/side" {
    var w: TestBits = .{};
    // ヘッダ: 固定ブロック長、ブロック長は 8 ビットで 4、サンプルレートは STREAMINFO、left/side、16bit、フレーム番号 0
    w.put(0xFFF8, 16);
    w.put(0x60, 8);
    w.put(0x88, 8);
    w.put(0, 8);
    w.put(3, 8);
    w.put(frame.Crc8.hash(w.buf[0..6]), 8);
    // 左: 定数 100(16 ビット)
    w.put(0b0_000000_0, 8);
    w.put(100, 16);
    // side: 無圧縮、無駄ビット 1(17 - 1 = 16 ビット)。値は 1, -2, 3, 0 → 2, -4, 6, 0
    w.put(0b0_000001_1, 8);
    w.put(1, 1);
    for ([_]i64{ 1, -2, 3, 0 }) |v| w.put(@bitCast(v & 0xFFFF), 16);
    w.pos = (w.pos + 7) / 8 * 8;
    const crc = frame.Crc16.hash(w.buf[0 .. w.pos / 8]);
    w.put(crc, 16);
    const bytes = w.buf[0 .. w.pos / 8];

    const h = Header.parse(bytes).?;
    try std.testing.expectEqual(4, h.block_size);
    try std.testing.expectEqual(bytes.len, frameLen(&w.buf, h, 16).?);
    var d: Decoder = .init(std.testing.allocator);
    defer d.deinit();
    const s = try d.decodeFrame(bytes, h, 16);
    try std.testing.expectEqualSlices(i64, &.{ 100, 100, 100, 100, 98, 104, 94, 100 }, s);
    // フレームの長さが 1 バイト足りない・余る
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame(bytes[0 .. bytes.len - 1], h, 16));
    try std.testing.expectError(error.InvalidFrame, d.decodeFrame(w.buf[0 .. bytes.len + 1], h, 16));
}
