// SPDX-License-Identifier: MIT AND CC0-1.0
//! Layer III の時間領域の処理: IMDCT(窓、重ね合わせ、周波数反転を含む)と、32 帯の合成フィルタバンク。
//! どちらも規格の式どおりに倍精度で計算する。
//!
//! 合成窓の係数は minimp3(CC0 1.0、コミット ea99364)の `g_win` と `mp3d_synth_pair` の定数から組み立てた
//! (規格 Table B.3 の D[i] × 65536。docs/mp3-decoder.md §1、THIRD_PARTY_NOTICES.md)。
//! 係数のデータは CC0 1.0、それ以外のコードは MIT。
const std = @import("std");

/// 合成窓の係数 D[i] × 65536(i = 0〜256。規格 Table B.3)。D[512 - i] は i が 64 の倍数でなければ -D[i]、64 の倍数なら D[i]
const enwindow = [257]i32{
    0,      -1,     -1,     -1,     -1,     -1,     -1,     -2,     -2,     -2,     -2,     -3,     -3,     -4,     -4,     -5,
    -5,     -6,     -7,     -7,     -8,     -9,     -10,    -11,    -13,    -14,    -16,    -17,    -19,    -21,    -24,    -26,
    -29,    -31,    -35,    -38,    -41,    -45,    -49,    -53,    -58,    -63,    -68,    -73,    -79,    -85,    -91,    -97,
    -104,   -111,   -117,   -125,   -132,   -139,   -147,   -154,   -161,   -169,   -176,   -183,   -190,   -196,   -202,   -208,
    213,    218,    222,    225,    227,    228,    228,    227,    224,    221,    215,    208,    200,    189,    177,    163,
    146,    127,    106,    83,     57,     29,     -2,     -36,    -72,    -111,   -153,   -197,   -244,   -294,   -347,   -401,
    -459,   -519,   -581,   -645,   -711,   -779,   -848,   -919,   -991,   -1064,  -1137,  -1210,  -1283,  -1356,  -1428,  -1498,
    -1567,  -1634,  -1698,  -1759,  -1817,  -1870,  -1919,  -1962,  -2001,  -2032,  -2057,  -2075,  -2085,  -2087,  -2080,  -2063,
    2037,   2000,   1952,   1893,   1822,   1739,   1644,   1535,   1414,   1280,   1131,   970,    794,    605,    402,    185,
    -45,    -288,   -545,   -814,   -1095,  -1388,  -1692,  -2006,  -2330,  -2663,  -3004,  -3351,  -3705,  -4063,  -4425,  -4788,
    -5153,  -5517,  -5879,  -6237,  -6589,  -6935,  -7271,  -7597,  -7910,  -8209,  -8491,  -8755,  -8998,  -9219,  -9416,  -9585,
    -9727,  -9838,  -9916,  -9959,  -9966,  -9935,  -9863,  -9750,  -9592,  -9389,  -9139,  -8840,  -8492,  -8092,  -7640,  -7134,
    6574,   5959,   5288,   4561,   3776,   2935,   2037,   1082,   70,     -998,   -2122,  -3300,  -4533,  -5818,  -7154,  -8540,
    -9975,  -11455, -12980, -14548, -16155, -17799, -19478, -21189, -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
    -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137, -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
    -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420, -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
    75038,
};

/// 合成窓 D[0..512](規格 Table B.3)
const window = blk: {
    var d: [512]f64 = undefined;
    for (0..257) |i| {
        const v: f64 = @as(f64, @floatFromInt(enwindow[i])) / 65536.0;
        d[i] = v;
        if (i != 0) d[512 - i] = if (i % 64 != 0) -v else v;
    }
    break :blk d;
};

/// 合成フィルタの行列 N[i][k] = cos((16 + i)(2k + 1)π / 64)
const synth_matrix = blk: {
    @setEvalBranchQuota(100_000);
    var n: [64][32]f64 = undefined;
    for (0..64) |i| for (0..32) |k| {
        n[i][k] = @cos(@as(f64, @floatFromInt((16 + i) * (2 * k + 1))) * std.math.pi / 64.0);
    };
    break :blk n;
};

/// 1 チャンネルの合成フィルタバンクの状態
pub const Synth = struct {
    v: [1024]f64 = @splat(0),
    offset: usize = 0,

    /// 32 サブバンドの 1 時刻分のサンプルから、PCM を 32 個作る
    pub fn run(s: *Synth, sub: *const [32]f64, out: *[32]f32) void {
        s.offset = (s.offset + 1024 - 64) % 1024;
        for (0..64) |i| {
            var acc: f64 = 0;
            for (sub, synth_matrix[i]) |x, c| acc += x * c;
            s.v[s.offset + i] = acc;
        }
        for (0..32) |j| {
            var acc: f64 = 0;
            for (0..8) |i| {
                acc += window[64 * i + j] * s.v[(s.offset + 128 * i + j) % 1024];
                acc += window[64 * i + 32 + j] * s.v[(s.offset + 128 * i + 96 + j) % 1024];
            }
            out[j] = @floatCast(acc);
        }
    }
};

/// 長いブロックの IMDCT の係数 cos(π/72 (2i + 1 + 18)(2k + 1))
const imdct36_cos = blk: {
    @setEvalBranchQuota(100_000);
    var c: [36][18]f64 = undefined;
    for (0..36) |i| for (0..18) |k| {
        c[i][k] = @cos(std.math.pi / 72.0 * @as(f64, @floatFromInt((2 * i + 1 + 18) * (2 * k + 1))));
    };
    break :blk c;
};

/// 短いブロックの IMDCT の係数 cos(π/24 (2i + 1 + 6)(2k + 1))
const imdct12_cos = blk: {
    @setEvalBranchQuota(10_000);
    var c: [12][6]f64 = undefined;
    for (0..12) |i| for (0..6) |k| {
        c[i][k] = @cos(std.math.pi / 24.0 * @as(f64, @floatFromInt((2 * i + 1 + 6) * (2 * k + 1))));
    };
    break :blk c;
};

/// 長いブロックの窓。添字はブロックの種類(0: 通常、1: 開始、3: 終了。2 は使わない)
const long_windows = blk: {
    @setEvalBranchQuota(10_000);
    var w: [4][36]f64 = @splat(@splat(0));
    for (0..36) |i| {
        const fi: f64 = @floatFromInt(i);
        const s36 = @sin(std.math.pi / 36.0 * (fi + 0.5));
        w[0][i] = s36;
        w[1][i] = if (i < 18) s36 else if (i < 24) 1 else if (i < 30) @sin(std.math.pi / 12.0 * (fi - 18 + 0.5)) else 0;
        w[3][i] = if (i < 6) 0 else if (i < 12) @sin(std.math.pi / 12.0 * (fi - 6 + 0.5)) else if (i < 18) 1 else s36;
    }
    break :blk w;
};

/// 短いブロックの窓 sin(π/12 (i + 0.5))
const short_window = blk: {
    var w: [12]f64 = undefined;
    for (0..12) |i| w[i] = @sin(std.math.pi / 12.0 * (@as(f64, @floatFromInt(i)) + 0.5));
    break :blk w;
};

/// 1 チャンネル・1 グラニュールの IMDCT。`xr` は並べ替えとエイリアス削減を済ませた周波数領域のサンプル、
/// `overlap` は前のグラニュールの後半(次のグラニュールに渡す分で上書きする)、`out` は [時刻][サブバンド]。
/// `block_type` はグラニュールのブロックの種類、`mixed` なら低い 2 サブバンドは通常の長いブロック
pub fn imdct(xr: *const [576]f64, overlap: *[32][18]f64, block_type: u2, mixed: bool, out: *[18][32]f64) void {
    for (0..32) |sb| {
        const x = xr[sb * 18 ..][0..18];
        var z: [36]f64 = @splat(0);
        if (block_type == 2 and !(mixed and sb < 2)) {
            // 短いブロック: 3 つの窓をそれぞれ 12 点で変換し、6 サンプルずつずらして重ねる
            for (0..3) |w| {
                for (0..12) |i| {
                    var acc: f64 = 0;
                    for (0..6) |k| acc += x[3 * k + w] * imdct12_cos[i][k];
                    z[6 + 6 * w + i] += acc * short_window[i];
                }
            }
        } else {
            // mixed なら、ブロックの種類によらず(開始・終了のブロックでも)低い 2 サブバンドは通常の窓(ffmpeg と同じ)
            const bt: u2 = if (block_type == 2 or (mixed and sb < 2)) 0 else block_type;
            for (0..36) |i| {
                var acc: f64 = 0;
                for (0..18) |k| acc += x[k] * imdct36_cos[i][k];
                z[i] = acc * long_windows[bt][i];
            }
        }
        for (0..18) |i| {
            var v = z[i] + overlap[sb][i];
            // 周波数反転: 奇数番目のサブバンドの奇数番目の時刻は符号を反転する
            if (sb % 2 == 1 and i % 2 == 1) v = -v;
            out[i][sb] = v;
            overlap[sb][i] = z[18 + i];
        }
    }
}

test "合成窓: 規格書の代表値" {
    try std.testing.expectEqual(0, window[0]);
    try std.testing.expectApproxEqAbs(-0.000015259, window[1], 1e-9);
    try std.testing.expectApproxEqAbs(0.003250122, window[64], 1e-9);
    try std.testing.expectApproxEqAbs(1.144989014, window[256], 1e-9);
    try std.testing.expectApproxEqAbs(1.144287109, window[257], 1e-9);
}

test "合成フィルタ: 無音からは無音" {
    var s: Synth = .{};
    var out: [32]f32 = undefined;
    for (0..20) |_| {
        s.run(&@as([32]f64, @splat(0)), &out);
        for (out) |v| try std.testing.expectEqual(0, v);
    }
}
