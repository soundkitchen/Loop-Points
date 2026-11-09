// SPDX-License-Identifier: MIT
//! FLAC エンコーダの線形予測(LPC)の分析: 窓関数、自己相関、Levinson-Durbin、係数の量子化。
//! 手順と既定値は libFLAC(BSD-3-Clause)のエンコーダの考え方に沿って書いた(コードは写していない)。
const std = @import("std");

pub const max_order = 32;

/// Tukey 窓を `w[start..end)` に書き、ほかは 0 にする。`taper` は片側のなだらかな部分のサンプル数
pub fn tukey(w: []f64, start: usize, end: usize, taper: usize) void {
    @memset(w, 0);
    if (end <= start) return;
    const n = end - start;
    @memset(w[start..end], 1);
    const t = @min(taper, n / 2);
    if (t < 2) return;
    const tf: f64 = @floatFromInt(t - 1);
    for (0..t) |i| {
        const v = 0.5 - 0.5 * @cos(std.math.pi * @as(f64, @floatFromInt(i)) / tf);
        w[start + i] = v;
        w[end - 1 - i] = v;
    }
}

/// `w` を 0 にする区間 `[start, end)` を、`taper` のなだらかな縁を付けてくり抜く(punchout)
pub fn punchout(w: []f64, start: usize, end: usize, taper: usize) void {
    if (end <= start) return;
    @memset(w[start..end], 0);
    const t = @min(taper, @min(start, w.len - end));
    if (t < 2) return;
    const tf: f64 = @floatFromInt(t - 1);
    for (0..t) |i| {
        const v = 0.5 + 0.5 * @cos(std.math.pi * @as(f64, @floatFromInt(i)) / tf);
        w[start - t + i] *= v;
        w[end + t - 1 - i] *= v;
    }
}

/// 窓関数の組。`subdivide`(N)は libFLAC の subdivide_tukey(N) に倣い、ブロック全体の Tukey 窓に、
/// 2〜N 等分した各部分の Tukey 窓(partial_tukey)と、3〜N 等分した各部分をくり抜いた窓(punchout_tukey)を足す。
/// なだらかな縁の長さは、いちばん小さい部分(ブロック長 / N)に Tukey(0.5) を当てたときと同じにする
pub fn windowCount(subdivide: u8) usize {
    var count: usize = 1;
    var k: usize = 2;
    while (k <= subdivide) : (k += 1) {
        count += k; // partial
        if (k >= 3) count += k; // punchout
    }
    return count;
}

/// `windows` に `windowCount(subdivide)` 個の窓(各 `n` サンプル)を書く
pub fn makeWindows(windows: []f64, n: usize, subdivide: u8) void {
    std.debug.assert(windows.len >= windowCount(subdivide) * n);
    // Tukey(p) の片側の縁は p / 2 × 長さ。subdivide 1 なら全体に Tukey(0.5)
    const taper = n / (4 * @as(usize, subdivide));
    var idx: usize = 0;
    tukey(windows[0..n], 0, n, taper);
    idx += 1;
    var k: usize = 2;
    while (k <= subdivide) : (k += 1) {
        for (0..k) |j| {
            const w = windows[idx * n ..][0..n];
            tukey(w, j * n / k, (j + 1) * n / k, taper);
            idx += 1;
        }
        if (k >= 3) for (0..k) |j| {
            const w = windows[idx * n ..][0..n];
            tukey(w, 0, n, taper);
            punchout(w, j * n / k, (j + 1) * n / k, taper);
            idx += 1;
        };
    }
}

/// 窓 `w` を掛けた `x` の自己相関 `autoc[0..=order]`。窓が 0 の両端は計算しない(partial_tukey の窓)
pub fn autocorrelation(x: []const i64, w: []const f64, buf: []f64, autoc: []f64) void {
    var lo: usize = 0;
    var hi: usize = x.len;
    while (lo < hi and w[lo] == 0) lo += 1;
    while (hi > lo and w[hi - 1] == 0) hi -= 1;
    const n = hi - lo;
    for (buf[0..n], x[lo..hi], w[lo..hi]) |*b, v, wv| b.* = @as(f64, @floatFromInt(v)) * wv;
    const d = buf[0..n];
    for (autoc, 0..) |*a, lag| {
        var s: f64 = 0;
        var i = lag;
        while (i < n) : (i += 1) s += d[i] * d[i - lag];
        a.* = s;
    }
}

/// Levinson-Durbin で、次数 1〜`orders` の予測係数(`coefs[o - 1][0..o]`、予測は Σ coefs[j] x[n - 1 - j])と
/// 予測誤差 `errors[o - 1]` を求め、求められた次数の数を返す。誤差が 0 になったらその次数まで、
/// 丸め誤差で反射係数の絶対値が 1 以上になった(誤差が負になる、不安定な)ときはその手前の次数までにする
pub fn levinson(autoc: []const f64, orders: usize, coefs: *[max_order][max_order]f64, errors: *[max_order]f64) usize {
    var a: [max_order]f64 = undefined;
    var err = autoc[0];
    for (0..orders) |i| {
        var r = -autoc[i + 1];
        for (0..i) |j| r -= a[j] * autoc[i - j];
        r /= err;
        if (!(@abs(r) < 1)) return i;
        a[i] = r;
        var j: usize = 0;
        while (j < i / 2) : (j += 1) {
            const t = a[j];
            a[j] += r * a[i - 1 - j];
            a[i - 1 - j] += r * t;
        }
        if (i & 1 == 1) a[j] += a[j] * r;
        err *= 1 - r * r;
        for (0..i + 1) |k| coefs[i][k] = -a[k];
        errors[i] = err;
        if (err <= 0) return i + 1;
    }
    return orders;
}

/// 予測誤差から、残差 1 サンプルあたりの見込みのビット数(誤差が負なら選ばれないよう無限大)
fn expectedBits(err: f64, n: usize) f64 {
    if (err < 0) return std.math.inf(f64);
    if (err == 0) return 0;
    const b = 0.5 * std.math.log2(err * 0.5 / @as(f64, @floatFromInt(n)));
    return @max(b, 0);
}

/// 見込みのビット数が最小になる次数(1 以上)。`overhead` は次数 1 つあたりのビット数(初期値と係数)
pub fn bestOrder(errors: []const f64, n: usize, overhead: f64) usize {
    var best: usize = 1;
    var best_bits = std.math.inf(f64);
    for (errors, 1..) |err, o| {
        if (o >= n) break;
        const bits = expectedBits(err, n - o) * @as(f64, @floatFromInt(n - o)) + @as(f64, @floatFromInt(o)) * overhead;
        if (bits < best_bits) {
            best_bits = bits;
            best = o;
        }
    }
    return best;
}

/// 係数を `precision` ビットの整数に量子化する。誤差を次の係数に持ち越す(丸め誤差をならす)。
/// シフト量(0〜15)を返す。シフトが負になる(係数が大きすぎる)ときは null
pub fn quantize(coefs: []const f64, precision: u5, out: []i32) ?u5 {
    var cmax: f64 = 0;
    for (coefs) |c| cmax = @max(cmax, @abs(c));
    if (cmax <= 0) return null;
    const log2cmax: i32 = blk: {
        const fr = std.math.frexp(cmax);
        break :blk fr.exponent - 1;
    };
    var shift: i32 = @as(i32, precision) - 1 - log2cmax - 1;
    if (shift > 15) shift = 15;
    if (shift < 0) return null;
    const qmax: i32 = (@as(i32, 1) << (precision - 1)) - 1;
    const qmin: i32 = -qmax - 1;
    const scale = std.math.ldexp(@as(f64, 1), shift);
    var e: f64 = 0;
    for (coefs, out) |c, *q| {
        e += c * scale;
        const v: i64 = @intFromFloat(@round(e));
        const cl: i32 = @intCast(std.math.clamp(v, qmin, qmax));
        q.* = cl;
        e -= @floatFromInt(cl);
    }
    return @intCast(shift);
}

test "levinson: AR(1) の信号は次数 1 の係数で予測できる" {
    // x[n] = 0.9 x[n-1] の自己相関は autoc[k] ∝ 0.9^k
    var autoc: [4]f64 = undefined;
    for (&autoc, 0..) |*a, k| a.* = std.math.pow(f64, 0.9, @floatFromInt(k));
    var coefs: [max_order][max_order]f64 = undefined;
    var errors: [max_order]f64 = undefined;
    const n = levinson(&autoc, 3, &coefs, &errors);
    try std.testing.expectEqual(3, n);
    try std.testing.expectApproxEqAbs(0.9, coefs[0][0], 1e-12);
    try std.testing.expectApproxEqAbs(0.0, coefs[1][1], 1e-12);
    try std.testing.expectApproxEqAbs(1 - 0.81, errors[0], 1e-12);
}

test "levinson: ほぼ完全に予測できる信号でも、不安定な次数を返さない" {
    // 純粋な正弦波の自己相関 cos(ωk) は次数 2 で誤差 0 になり、それより上は丸め誤差で不安定になりうる
    var autoc: [9]f64 = undefined;
    for (&autoc, 0..) |*a, k| a.* = @cos(0.3 * @as(f64, @floatFromInt(k)));
    var coefs: [max_order][max_order]f64 = undefined;
    var errors: [max_order]f64 = undefined;
    const got = levinson(&autoc, 8, &coefs, &errors);
    try std.testing.expect(got >= 1 and got <= 8);
    for (errors[0..got]) |e| try std.testing.expect(e >= 0);
    for (0..got) |o| for (coefs[o][0 .. o + 1]) |c| try std.testing.expect(std.math.isFinite(c));
    // 負の誤差の次数は選ばない
    try std.testing.expectEqual(1, bestOrder(&.{ 1.0, -1e-9 }, 4096, 20));
}

test "quantize" {
    var q: [2]i32 = undefined;
    // 1.5 と -0.75 を 12 ビットで: cmax 1.5 → log2 0 → shift 10
    const s = quantize(&.{ 1.5, -0.75 }, 12, &q).?;
    try std.testing.expectEqual(10, s);
    try std.testing.expectEqualSlices(i32, &.{ 1536, -768 }, &q);
    // 係数が大きすぎてシフトが負になる
    try std.testing.expectEqual(null, quantize(&.{5000.0}, 5, &q));
}

test makeWindows {
    try std.testing.expectEqual(1, windowCount(1));
    try std.testing.expectEqual(3, windowCount(2));
    try std.testing.expectEqual(9, windowCount(3));
    var w: [9 * 64]f64 = undefined;
    makeWindows(&w, 64, 3);
    // 全体の窓は中央が 1、端が 0
    try std.testing.expectEqual(1, w[32]);
    try std.testing.expectEqual(0, w[0]);
    // partial(2) の 1 つ目は後半が 0
    try std.testing.expectEqual(0, w[64 + 40]);
    // 0: 全体、1〜2: partial(2)、3〜5: partial(3)、6〜8: punchout(3)。punchout(3) の 1 つ目は先頭の 1/3 が 0
    try std.testing.expectEqual(0, w[6 * 64 + 10]);
    try std.testing.expectEqual(1, w[6 * 64 + 45]);
}
