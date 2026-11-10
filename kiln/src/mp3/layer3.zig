// SPDX-License-Identifier: MIT
//! Layer III の 1 グラニュールの復号のうち、周波数領域の処理(サイド情報、スケールファクタ、
//! ハフマン復号、逆量子化、ステレオ処理、短いブロックの並べ替え、エイリアス削減)。
//!
//! 細かい扱い(ビットの読みすぎ、MS ステレオの正規化、インテンシティステレオの最後の帯など)は
//! ffmpeg の mpegaudio デコーダに合わせている(docs/mp3-decoder.md)。
const std = @import("std");
const Reader = @import("bits.zig").Reader;
const huffman = @import("huffman.zig");

pub const Error = error{
    /// サイド情報が規格に合わない(big_values が 288 を超える、窓切り替えなのにブロックの種類が 0)
    InvalidFrame,
};

/// 1 グラニュール・1 チャンネルのサイド情報
pub const Granule = struct {
    part2_3_length: u16 = 0,
    big_values: u16 = 0,
    global_gain: u8 = 0,
    scalefac_compress: u4 = 0,
    window_switching: bool = false,
    /// 0: 通常、1: 開始、2: 短いブロック、3: 終了
    block_type: u2 = 0,
    /// 短いブロックのうち、低い 2 サブバンドだけ長いブロックにする(mixed block)
    mixed: bool = false,
    table_select: [3]u5 = .{ 0, 0, 0 },
    subblock_gain: [3]u3 = .{ 0, 0, 0 },
    region0_count: u4 = 0,
    region1_count: u3 = 0,
    preflag: bool = false,
    scalefac_scale: bool = false,
    count1_table_b: bool = false,

    /// 短いブロック(mixed を含む)か
    pub fn isShort(g: *const Granule) bool {
        return g.window_switching and g.block_type == 2;
    }

    /// 長いスケールファクタ帯で扱う帯の数(この帯の手前まで長いブロック)
    fn longEnd(g: *const Granule) usize {
        if (!g.isShort()) return 22;
        return if (g.mixed) 8 else 0;
    }

    /// 短いスケールファクタ帯で扱う最初の帯
    fn shortStart(g: *const Granule) usize {
        if (!g.isShort()) return 13;
        return if (g.mixed) 3 else 0;
    }
};

pub const SideInfo = struct {
    main_data_begin: u16,
    scfsi: [2][4]bool,
    /// [グラニュール][チャンネル]
    granules: [2][2]Granule,
};

/// サイド情報を読む(MPEG-1)
pub fn readSideInfo(r: *Reader, channels: u8) Error!SideInfo {
    var si: SideInfo = .{
        .main_data_begin = @intCast(r.read(9)),
        .scfsi = @splat(@splat(false)),
        .granules = @splat(@splat(.{})),
    };
    r.skip(if (channels == 1) 5 else 3); // private_bits
    for (0..channels) |ch| {
        for (&si.scfsi[ch]) |*s| s.* = r.readBool();
    }
    for (0..2) |gr| {
        for (0..channels) |ch| {
            const g = &si.granules[gr][ch];
            g.part2_3_length = @intCast(r.read(12));
            g.big_values = @intCast(r.read(9));
            if (g.big_values > 288) return error.InvalidFrame;
            g.global_gain = @intCast(r.read(8));
            g.scalefac_compress = @intCast(r.read(4));
            g.window_switching = r.readBool();
            if (g.window_switching) {
                g.block_type = @intCast(r.read(2));
                if (g.block_type == 0) return error.InvalidFrame;
                g.mixed = r.readBool();
                for (g.table_select[0..2]) |*t| t.* = @intCast(r.read(5));
                for (&g.subblock_gain) |*s| s.* = @intCast(r.read(3));
            } else {
                for (&g.table_select) |*t| t.* = @intCast(r.read(5));
                g.region0_count = @intCast(r.read(4));
                g.region1_count = @intCast(r.read(3));
            }
            g.preflag = r.readBool();
            g.scalefac_scale = r.readBool();
            g.count1_table_b = r.readBool();
        }
    }
    return si;
}

/// サイド情報のバイト数(MPEG-1)
pub fn sideInfoLen(channels: u8) usize {
    return if (channels == 1) 17 else 32;
}

/// スケールファクタ帯の境界(サンプル位置)。添字はサンプルレートの番号(44.1 / 48 / 32kHz)
const long_bounds = [3][23]u16{
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576 },
};
/// 短いブロックの帯の境界(1 つの窓の中のサンプル位置)
const short_bounds = [3][14]u8{
    .{ 0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192 },
    .{ 0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192 },
    .{ 0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192 },
};

fn longWidth(sr: usize, sfb: usize) usize {
    return long_bounds[sr][sfb + 1] - long_bounds[sr][sfb];
}

fn shortWidth(sr: usize, sfb: usize) usize {
    return short_bounds[sr][sfb + 1] - short_bounds[sr][sfb];
}

/// scalefac_compress から (slen1, slen2)
const slen = [16][2]u5{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 3, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 3 },
    .{ 2, 1 }, .{ 2, 2 }, .{ 2, 3 }, .{ 3, 1 }, .{ 3, 2 }, .{ 3, 3 }, .{ 4, 2 }, .{ 4, 3 },
};

/// preflag のときに長いスケールファクタ帯に足す値
const pretab = [22]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };

pub const Scalefactors = struct {
    long: [22]u8 = @splat(0),
    /// [帯][窓]
    short: [13][3]u8 = @splat(@splat(0)),
};

/// スケールファクタ(part2)を読む。`prev` は同じチャンネルのグラニュール 0 のもの(scfsi で使い回す)
pub fn readScalefactors(r: *Reader, g: *const Granule, scfsi: [4]bool, gr: usize, prev: *const Scalefactors, out: *Scalefactors) void {
    const s1 = slen[g.scalefac_compress][0];
    const s2 = slen[g.scalefac_compress][1];
    if (g.isShort()) {
        out.* = .{};
        var sfb: usize = 0;
        if (g.mixed) {
            for (out.long[0..8]) |*v| v.* = @intCast(r.read(s1));
            sfb = 3;
        }
        while (sfb < 12) : (sfb += 1) {
            const n = if (sfb < 6) s1 else s2;
            for (&out.short[sfb]) |*v| v.* = @intCast(r.read(n));
        }
        return;
    }
    // 長いブロック: 帯 0〜5 / 6〜10 / 11〜15 / 16〜20 の 4 つの組ごとに、グラニュール 1 では scfsi で使い回せる
    const groups = [5]usize{ 0, 6, 11, 16, 21 };
    for (0..4) |k| {
        const n = if (k < 2) s1 else s2;
        for (groups[k]..groups[k + 1]) |sfb| {
            out.long[sfb] = if (gr == 1 and scfsi[k]) prev.long[sfb] else @intCast(r.read(n));
        }
    }
    out.long[21] = 0;
}

/// ハフマン符号の部分を復号して、量子化値を `out` に入れる。`end` はこのグラニュールの終わりのビット位置。
/// 読み終えた位置は `end`(読みすぎたときはその位置)になる
pub fn decodeHuffman(r: *Reader, g: *const Granule, sr: usize, end: usize, out: *[576]i32) void {
    // 領域の境界(2 値の組の数)。窓切り替えのときは 36 サンプルで区切る
    var bounds: [3]usize = undefined;
    if (g.window_switching) {
        bounds = .{ 36 / 2, 576 / 2, 576 / 2 };
    } else {
        const l = @min(@as(usize, g.region0_count) + g.region1_count + 2, 22);
        bounds = .{ long_bounds[sr][@as(usize, g.region0_count) + 1] / 2, long_bounds[sr][l] / 2, 576 / 2 };
    }
    var idx: usize = 0;
    var prev: usize = 0;
    for (0..3) |i| {
        const k = @min(bounds[i], g.big_values);
        const pairs = k -| prev;
        prev = @max(prev, k);
        const table = g.table_select[i];
        for (0..pairs) |_| {
            const v: [2]i32 = if (table == 0) .{ 0, 0 } else huffman.decodePair(r, table);
            out[idx] = v[0];
            out[idx + 1] = v[1];
            idx += 2;
        }
    }

    // count1 の領域。グラニュールの終わりを越えて読んだ最後の組は捨てる(ffmpeg と同じ)
    var last_pos: ?usize = null;
    while (idx <= 572) {
        if (r.pos >= end) {
            if (r.pos > end and last_pos != null) {
                idx -= 4;
                r.pos = last_pos.?;
            }
            break;
        }
        last_pos = r.pos;
        const q = huffman.decodeQuad(r, g.count1_table_b);
        @memcpy(out[idx..][0..4], &q);
        idx += 4;
    }
    @memset(out[idx..], 0);
    if (r.pos < end) r.pos = end;
}

/// 2^(n / 4)(n = 0〜3)
const quarter_pow2 = [4]f64{ 1.0, 1.189207115002721, 1.4142135623730951, 1.6817928305074290 };

fn pow2Quarter(e: i32) f64 {
    return std.math.ldexp(quarter_pow2[@intCast(e & 3)], e >> 2);
}

fn dequant(v: i32, e: i32) f64 {
    if (v == 0) return 0;
    const a = std.math.pow(f64, @floatFromInt(@abs(v)), 4.0 / 3.0) * pow2Quarter(e);
    return if (v < 0) -a else a;
}

/// 逆量子化。`ms_gain` が真なら、MS ステレオの 1/√2 を global_gain に含める(ffmpeg と同じく 2 を引く)
pub fn requantize(g: *const Granule, sf: *const Scalefactors, sr: usize, ms_gain: bool, in: *const [576]i32, out: *[576]f64) void {
    const gain: i32 = @as(i32, g.global_gain) - 210 - @as(i32, if (ms_gain) 2 else 0);
    const shift: u5 = if (g.scalefac_scale) 2 else 1;
    var i: usize = 0;
    for (0..g.longEnd()) |sfb| {
        var s: i32 = sf.long[sfb];
        if (g.preflag) s += pretab[sfb];
        const e = gain - (s << shift);
        for (0..longWidth(sr, sfb)) |_| {
            out[i] = dequant(in[i], e);
            i += 1;
        }
    }
    for (g.shortStart()..13) |sfb| {
        for (0..3) |w| {
            const e = gain - 8 * @as(i32, g.subblock_gain[w]) - (@as(i32, sf.short[sfb][w]) << shift);
            for (0..shortWidth(sr, sfb)) |_| {
                out[i] = dequant(in[i], e);
                i += 1;
            }
        }
    }
    std.debug.assert(i == 576);
}

/// インテンシティステレオの係数 [0]: 左、[1]: 右(位置 0〜6。7 は使わない)
const is_ratio = blk: {
    var t: [2][7]f64 = undefined;
    for (0..7) |i| {
        if (i == 6) {
            t[0][i] = 1;
            t[1][i] = 0;
        } else {
            const tan = @tan(@as(f64, @floatFromInt(i)) * std.math.pi / 12.0);
            t[0][i] = tan / (1 + tan);
            t[1][i] = 1 / (1 + tan);
        }
    }
    break :blk t;
};

fn msBand(l: []f64, r: []f64, scale: f64) void {
    for (l, r) |*a, *b| {
        const x = a.*;
        const y = b.*;
        a.* = (x + y) * scale;
        b.* = (x - y) * scale;
    }
}

fn allZero(v: []const f64) bool {
    for (v) |x| if (x != 0) return false;
    return true;
}

/// ジョイントステレオの処理。`g1` / `sf1` は右チャンネルのもの。並べ替えの前(帯・窓ごとに並んだ状態)に行う
pub fn stereo(mode_ext: u2, g1: *const Granule, sf1: *const Scalefactors, sr: usize, l: *[576]f64, r: *[576]f64) void {
    const ms = mode_ext & 2 != 0;
    if (mode_ext & 1 == 0) {
        // MS だけ: 1/√2 は global_gain に含めてある
        if (ms) msBand(l, r, 1);
        return;
    }
    const isqrt2 = std.math.sqrt1_2;
    // 高い帯から順に、右チャンネルが 0 の帯をインテンシティステレオで復元する。0 でない帯が見つかったら、
    // そこから下は MS(有効なら)
    var pos: usize = 576;
    var nonzero_short = [3]bool{ false, false, false };
    var sfb: usize = 12;
    while (sfb + 1 > g1.shortStart()) : (sfb -%= 1) {
        const len = shortWidth(sr, sfb);
        // 最後の帯(12)は、帯 11 の位置を使う
        const k = if (sfb == 12) 11 else sfb;
        var w: usize = 3;
        while (w > 0) {
            w -= 1;
            pos -= len;
            const lb = l[pos..][0..len];
            const rb = r[pos..][0..len];
            if (!nonzero_short[w]) {
                if (!allZero(rb)) {
                    nonzero_short[w] = true;
                } else {
                    const p = sf1.short[k][w];
                    if (p < 7) {
                        for (lb, rb) |*a, *b| {
                            const x = a.*;
                            a.* = x * is_ratio[0][p];
                            b.* = x * is_ratio[1][p];
                        }
                        continue;
                    }
                }
            }
            if (ms) msBand(lb, rb, isqrt2);
        }
        if (sfb == 0) break;
    }
    var nonzero = nonzero_short[0] or nonzero_short[1] or nonzero_short[2];
    var i = g1.longEnd();
    while (i > 0) {
        i -= 1;
        const len = longWidth(sr, i);
        pos -= len;
        const lb = l[pos..][0..len];
        const rb = r[pos..][0..len];
        if (!nonzero) {
            if (!allZero(rb)) {
                nonzero = true;
            } else {
                // 最後の帯(21)は、帯 20 の位置を使う
                const p = sf1.long[if (i == 21) 20 else i];
                if (p < 7) {
                    for (lb, rb) |*a, *b| {
                        const x = a.*;
                        a.* = x * is_ratio[0][p];
                        b.* = x * is_ratio[1][p];
                    }
                    continue;
                }
            }
        }
        if (ms) msBand(lb, rb, isqrt2);
    }
    std.debug.assert(pos == 0);
}

/// 短いブロックを、帯ごと・窓ごとの並び([帯][窓][周波数])から、IMDCT が使う並び([帯][周波数][窓])にする
pub fn reorder(g: *const Granule, sr: usize, xr: *[576]f64) void {
    if (!g.isShort()) return;
    var pos: usize = if (g.mixed) 36 else 0;
    var tmp: [576]f64 = undefined;
    for (g.shortStart()..13) |sfb| {
        const len = shortWidth(sr, sfb);
        for (0..len) |j| {
            for (0..3) |w| tmp[3 * j + w] = xr[pos + w * len + j];
        }
        @memcpy(xr[pos..][0 .. 3 * len], tmp[0 .. 3 * len]);
        pos += 3 * len;
    }
}

/// エイリアス削減のバタフライの係数(cs, ca)
const alias = blk: {
    const c = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };
    var t: [2][8]f64 = undefined;
    for (c, 0..) |ci, i| {
        const s = 1.0 / @sqrt(1.0 + ci * ci);
        t[0][i] = s;
        t[1][i] = ci * s;
    }
    break :blk t;
};

/// エイリアス削減。長いブロックは全サブバンドの境界、mixed は最初の境界だけ、短いブロックは行わない
pub fn antialias(g: *const Granule, xr: *[576]f64) void {
    const n: usize = if (g.isShort()) (if (g.mixed) 1 else 0) else 31;
    for (1..n + 1) |sb| {
        for (0..8) |i| {
            const bu = xr[18 * sb - 1 - i];
            const bd = xr[18 * sb + i];
            xr[18 * sb - 1 - i] = bu * alias[0][i] - bd * alias[1][i];
            xr[18 * sb + i] = bu * alias[1][i] + bd * alias[0][i];
        }
    }
}

test "スケールファクタ帯の境界は 576 / 192 で終わり、単調に増える" {
    for (long_bounds) |b| {
        try std.testing.expectEqual(576, b[22]);
        for (b[1..], b[0..22]) |x, y| try std.testing.expect(x > y);
    }
    for (short_bounds) |b| {
        try std.testing.expectEqual(192, b[13]);
        for (b[1..], b[0..13]) |x, y| try std.testing.expect(x > y);
    }
}

test "エイリアス削減の係数は cs^2 + ca^2 = 1" {
    for (0..8) |i| try std.testing.expectApproxEqAbs(1.0, alias[0][i] * alias[0][i] + alias[1][i] * alias[1][i], 1e-15);
}

test reorder {
    var g: Granule = .{ .window_switching = true, .block_type = 2 };
    var xr: [576]f64 = undefined;
    for (&xr, 0..) |*v, i| v.* = @floatFromInt(i);
    reorder(&g, 0, &xr);
    // 帯 0 は幅 4: [w0: 0..3][w1: 4..7][w2: 8..11] → 0,4,8,1,5,9,...
    try std.testing.expectEqualSlices(f64, &.{ 0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11 }, xr[0..12]);
    g.mixed = true;
    for (&xr, 0..) |*v, i| v.* = @floatFromInt(i);
    reorder(&g, 0, &xr);
    // mixed は 36 サンプル目から(帯 3、幅 4)
    try std.testing.expectEqual(35, xr[35]);
    try std.testing.expectEqualSlices(f64, &.{ 36, 40, 44, 37 }, xr[36..40]);
}
