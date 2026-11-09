//! PCM のサンプル形式と、形式どうしの変換。
//!
//! PCM は読み込んだ元の形式(8bit 符号なし、16 / 24 / 32bit 整数、32 / 64bit 浮動小数点)のまま
//! バイト列で持ち、必要なときだけ f32 との間で変換する。整数と浮動小数点の対応は
//! `値 / 2^(bits - 1)` で、整数 → f32 → 整数(16 / 24bit)は元に戻る。
//! バイト列はリトルエンディアンで、チャンネルはインターリーブ(WAV と同じ並び)。
const std = @import("std");

pub const Format = enum {
    /// 8bit 符号なし整数(128 が無音)
    u8,
    i16,
    /// 24bit 整数(3 バイト詰め)
    i24,
    i32,
    f32,
    f64,

    /// 1 サンプルのバイト数
    pub fn bytes(f: Format) u8 {
        return switch (f) {
            .u8 => 1,
            .i16 => 2,
            .i24 => 3,
            .i32, .f32 => 4,
            .f64 => 8,
        };
    }

    pub fn bits(f: Format) u8 {
        return f.bytes() * 8;
    }

    pub fn isFloat(f: Format) bool {
        return f == .f32 or f == .f64;
    }

    /// 整数形式の満幅(2^(bits - 1))。浮動小数点との変換の倍率
    fn scale(f: Format) f64 {
        return std.math.ldexp(@as(f64, 1), @as(i32, f.bits()) - 1);
    }
};

/// 浮動小数点から整数に変換するときのディザ
pub const Dither = enum {
    /// 四捨五入して、範囲外はクリップする
    none,
    /// TPDF(三角分布、振幅 ±1 LSB)のディザを足してから丸める
    tpdf,
};

/// 浮動小数点から整数への変換器。TPDF ディザの乱数の状態を持つ。
/// 乱数の種は固定なので、同じ入力からは毎回同じ結果になる
pub const Quantizer = struct {
    dither: Dither,
    rng: std.Random.DefaultPrng,

    pub const seed = 0x6B696C6E; // "kiln"

    pub fn init(dither: Dither) Quantizer {
        return .{ .dither = dither, .rng = .init(seed) };
    }

    /// `x`(満幅を ±1 とする値)を整数形式 `f` の値にする
    fn quantize(q: *Quantizer, f: Format, x: f64) i64 {
        const s = f.scale();
        var v = if (std.math.isNan(x)) 0 else x * s;
        if (q.dither == .tpdf) {
            const r = q.rng.random();
            v += r.float(f64) - r.float(f64);
        }
        v = @round(v);
        return @intFromFloat(std.math.clamp(v, -s, s - 1));
    }
};

/// `src`(形式 `f` のバイト列)を f32 にする。`dst.len` はサンプル数で、`src.len == dst.len * f.bytes()`
pub fn toF32(f: Format, src: []const u8, dst: []f32) void {
    std.debug.assert(src.len == dst.len * f.bytes());
    const n = f.bytes();
    const inv: f64 = 1 / f.scale();
    for (dst, 0..) |*d, i| {
        const b = src[i * n ..][0..n];
        d.* = switch (f) {
            .u8 => @floatCast(@as(f64, @floatFromInt(@as(i16, b[0]) - 128)) * inv),
            .i16 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) * inv),
            .i24 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) * inv),
            .i32 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) * inv),
            .f32 => @bitCast(std.mem.readInt(u32, b[0..4], .little)),
            .f64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little)))),
        };
    }
}

/// f32 の `src` を形式 `f` のバイト列にする。`dst.len == src.len * f.bytes()`。
/// 整数形式へは `q` のディザで丸め、範囲外はクリップする。浮動小数点形式へはそのまま(クリップしない)
pub fn fromF32(f: Format, src: []const f32, dst: []u8, q: *Quantizer) void {
    std.debug.assert(dst.len == src.len * f.bytes());
    const n = f.bytes();
    for (src, 0..) |x, i| {
        const b = dst[i * n ..][0..n];
        switch (f) {
            .u8 => b[0] = @intCast(q.quantize(f, x) + 128),
            .i16 => std.mem.writeInt(i16, b[0..2], @intCast(q.quantize(f, x)), .little),
            .i24 => std.mem.writeInt(i24, b[0..3], @intCast(q.quantize(f, x)), .little),
            .i32 => std.mem.writeInt(i32, b[0..4], @intCast(q.quantize(f, x)), .little),
            .f32 => std.mem.writeInt(u32, b[0..4], @bitCast(x), .little),
            .f64 => std.mem.writeInt(u64, b[0..8], @bitCast(@as(f64, x)), .little),
        }
    }
}

test "整数 → f32 → 整数で元に戻る(16 / 24bit、8bit)" {
    var q: Quantizer = .init(.none);
    inline for (.{ Format.u8, Format.i16, Format.i24 }) |f| {
        var src: [6 * f.bytes()]u8 = undefined;
        var x: [6]f32 = undefined;
        var back: [src.len]u8 = undefined;
        // 最小値・最大値・0 付近を含む値
        const full: i64 = @intFromFloat(f.scale());
        const vals = [_]i64{ -full, full - 1, 0, 1, -1, @rem(12345, full) };
        for (vals, 0..) |v, i| {
            const b = src[i * f.bytes() ..][0..f.bytes()];
            switch (f) {
                .u8 => b[0] = @intCast(v + 128),
                .i16 => std.mem.writeInt(i16, b[0..2], @intCast(v), .little),
                .i24 => std.mem.writeInt(i24, b[0..3], @intCast(v), .little),
                else => unreachable,
            }
        }
        toF32(f, &src, &x);
        fromF32(f, &x, &back, &q);
        try std.testing.expectEqualSlices(u8, &src, &back);
    }
}

test "f32 → 16bit: 四捨五入とクリップ" {
    var q: Quantizer = .init(.none);
    const src = [_]f32{ 0, 1.0, -1.0, 2.0, -2.0, 0.5 / 32768.0 * 1.0001, std.math.nan(f32), 1000.4 / 32768.0 };
    var dst: [src.len * 2]u8 = undefined;
    fromF32(.i16, &src, &dst, &q);
    var got: [src.len]i16 = undefined;
    for (&got, 0..) |*g, i| g.* = std.mem.readInt(i16, dst[i * 2 ..][0..2], .little);
    try std.testing.expectEqualSlices(i16, &.{ 0, 32767, -32768, 32767, -32768, 1, 0, 1000 }, &got);
}

test "f32 / f64 はそのまま" {
    var q: Quantizer = .init(.tpdf);
    const src = [_]f32{ 0.25, -1.5, 3.0 };
    var b32: [12]u8 = undefined;
    var b64: [24]u8 = undefined;
    var back: [3]f32 = undefined;
    fromF32(.f32, &src, &b32, &q);
    toF32(.f32, &b32, &back);
    try std.testing.expectEqualSlices(f32, &src, &back);
    fromF32(.f64, &src, &b64, &q);
    toF32(.f64, &b64, &back);
    try std.testing.expectEqualSlices(f32, &src, &back);
}

test "TPDF ディザ: 毎回同じ結果で、誤差は ±1 LSB 程度、平均は 0 付近" {
    const n = 4096;
    var src: [n]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = @floatCast(0.3 * @sin(@as(f64, @floatFromInt(i)) * 0.01));
    var a: [n * 2]u8 = undefined;
    var b: [n * 2]u8 = undefined;
    var qa: Quantizer = .init(.tpdf);
    var qb: Quantizer = .init(.tpdf);
    fromF32(.i16, &src, &a, &qa);
    fromF32(.i16, &src, &b, &qb);
    try std.testing.expectEqualSlices(u8, &a, &b);

    var sum: f64 = 0;
    for (src, 0..) |x, i| {
        const v: f64 = @floatFromInt(std.mem.readInt(i16, a[i * 2 ..][0..2], .little));
        const err = v - @as(f64, x) * 32768;
        try std.testing.expect(@abs(err) <= 1.5);
        sum += err;
    }
    try std.testing.expect(@abs(sum / n) < 0.1);

    // ディザなしとは結果が変わる
    var c: [n * 2]u8 = undefined;
    var qn: Quantizer = .init(.none);
    fromF32(.i16, &src, &c, &qn);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}
