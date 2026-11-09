// SPDX-License-Identifier: MIT
//! FLAC のエンコーダ(RFC 9639)。整数の PCM をブロックに分け、サブフレームごとに定数・無圧縮・
//! 固定予測・線形予測(LPC)のうち最も小さくなるものを選び、残差を Rice 符号で書く。
//!
//! 圧縮の段階 0〜8 は flac コマンドの -0〜-8 に合わせた(docs/flac.md §6)。手順の考え方は libFLAC
//! (BSD-3-Clause)に沿って書いた(コードは写していない)。
const std = @import("std");
const Io = std.Io;
const pcm = @import("../pcm.zig");
const frame = @import("frame.zig");
const bits = @import("bits.zig");
const lpc = @import("lpc.zig");

pub const max_compression = 8;

const Stereo = enum {
    /// チャンネルごとに独立
    independent,
    /// 固定予測の見積もりで相関除去の方式を選ぶ(flac の -M)
    adaptive,
    /// 4 通りの方式をすべて符号化して最小のものを選ぶ(flac の -m)
    exhaustive,
};

const Preset = struct {
    block_size: u32,
    /// LPC の最大次数(0 なら固定予測だけ)
    max_lpc_order: u8,
    stereo: Stereo,
    /// Rice 符号の分割の最大次数
    max_porder: u4,
    /// 窓関数の組(lpc.makeWindows。1 なら Tukey(0.5) だけ)
    subdivide: u8,
};

/// flac 1.5 の -0〜-8 と同じ設定
const presets = [max_compression + 1]Preset{
    .{ .block_size = 1152, .max_lpc_order = 0, .stereo = .independent, .max_porder = 3, .subdivide = 1 },
    .{ .block_size = 1152, .max_lpc_order = 0, .stereo = .adaptive, .max_porder = 3, .subdivide = 1 },
    .{ .block_size = 1152, .max_lpc_order = 0, .stereo = .exhaustive, .max_porder = 3, .subdivide = 1 },
    .{ .block_size = 4096, .max_lpc_order = 6, .stereo = .independent, .max_porder = 4, .subdivide = 1 },
    .{ .block_size = 4096, .max_lpc_order = 8, .stereo = .adaptive, .max_porder = 4, .subdivide = 1 },
    .{ .block_size = 4096, .max_lpc_order = 8, .stereo = .exhaustive, .max_porder = 5, .subdivide = 1 },
    .{ .block_size = 4096, .max_lpc_order = 8, .stereo = .exhaustive, .max_porder = 6, .subdivide = 2 },
    .{ .block_size = 4096, .max_lpc_order = 12, .stereo = .exhaustive, .max_porder = 6, .subdivide = 2 },
    .{ .block_size = 4096, .max_lpc_order = 12, .stereo = .exhaustive, .max_porder = 6, .subdivide = 3 },
};

pub const Options = struct {
    sample_rate: u32,
    channels: u8,
    /// 4〜32
    bits_per_sample: u8,
    /// 圧縮の段階(0〜8。flac の -0〜-8)
    compression: u8 = 5,
    /// 書くサンプル数。分かっていれば STREAMINFO に最初から書き、`finish` で書いた数と合うかを確かめる
    total_samples: ?u64 = null,
    /// `writeF32` で整数にするときのディザ
    dither: pcm.Dither = .tpdf,
    /// Vorbis コメントのベンダー文字列
    vendor: []const u8 = "kiln",
};

pub const InitError = Io.Writer.Error || error{ InvalidOptions, OutOfMemory };
pub const WriteError = Io.Writer.Error || error{ OutOfMemory, TooLarge };
pub const Error = WriteError || error{
    /// `Options.total_samples` と書いたサンプル数が違う
    LengthMismatch,
};

/// STREAMINFO の書き戻し(`finish` が返す)。出力の先頭から `offset` バイト目に `bytes` を上書きする
pub const StreamInfoPatch = struct {
    offset: usize,
    bytes: [34]u8,
};

/// STREAMINFO の位置(`fLaC` とメタデータブロックのヘッダの後)
const stream_info_offset = 8;
/// 36 ビットの総サンプル数の上限
const max_total = (1 << 36) - 1;
/// 残差は 32 ビットの符号付き整数に収まること(RFC 9639 §9.2.7。最小値は除く)
const max_residual = (1 << 31) - 1;
/// Rice 符号の分割の最大次数(この実装の上限。段階の設定は 6 まで)
const max_porder_limit = 8;

const Kind = enum { constant, verbatim, fixed, lpc };

/// 1 サブフレームの符号化の方法と、そのビット数
const Plan = struct {
    kind: Kind = .verbatim,
    /// 無駄ビット(すべてのサンプルの下位で 0 のビット数)
    wasted: u6 = 0,
    /// 無駄ビットを除いたビット数
    bps: u6 = 0,
    order: u8 = 0,
    precision: u5 = 0,
    shift: u5 = 0,
    coefs: [lpc.max_order]i32 = undefined,
    porder: u4 = 0,
    /// 分割ごとの Rice 符号のパラメータ
    params: [1 << max_porder_limit]u5 = undefined,
    /// パラメータのビット数(4 か 5)
    param_bits: u6 = 4,
    /// どちらの残差の作業領域にあるか
    res: u1 = 0,
    bits: u64 = std.math.maxInt(u64),
};

/// 1 チャンネル分の作業領域(無駄ビットを除いた信号と、残差 2 つ)
const Slot = struct {
    sig: []i64,
    res: [2][]i64,
    plan: Plan = .{},
};

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    options: Options,
    fe: FrameEncoder,
    /// たまっている PCM(チャンネルごとに block_size 個ずつ)
    block: []i64,
    fill: usize = 0,
    frame_number: u64 = 0,
    total: u64 = 0,
    md5: std.crypto.hash.Md5,
    min_frame: u32 = std.math.maxInt(u32),
    max_frame: u32 = 0,
    q: pcm.Quantizer,

    pub fn init(gpa: std.mem.Allocator, w: *Io.Writer, options: Options) InitError!Encoder {
        if (options.total_samples) |t| if (t > max_total) return error.InvalidOptions;
        if (options.vendor.len > 1 << 20) return error.InvalidOptions;
        var fe: FrameEncoder = try .init(gpa, .{
            .sample_rate = options.sample_rate,
            .channels = options.channels,
            .bits_per_sample = options.bits_per_sample,
            .compression = options.compression,
        }, null);
        errdefer fe.deinit();
        const block = try gpa.alloc(i64, fe.preset.block_size * options.channels);
        errdefer gpa.free(block);
        var e: Encoder = .{
            .gpa = gpa,
            .w = w,
            .options = options,
            .fe = fe,
            .block = block,
            .md5 = .init(.{}),
            .q = .init(options.dither),
        };
        try e.writeHeader();
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        e.gpa.free(e.block);
        e.fe.deinit();
        e.* = undefined;
    }

    /// `fLaC`、STREAMINFO(仮)、Vorbis コメント(ベンダー文字列だけ)を書く
    fn writeHeader(e: *Encoder) Io.Writer.Error!void {
        try e.w.writeAll("fLaC");
        try e.w.writeAll(&.{ 0x00, 0x00, 0x00, 0x22 });
        try e.w.writeAll(&e.streamInfo());
        const vlen = e.options.vendor.len;
        var h: [4]u8 = undefined;
        std.mem.writeInt(u32, &h, @intCast(0x84000000 | (4 + vlen + 4)), .big);
        try e.w.writeAll(&h);
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(vlen), .little);
        try e.w.writeAll(&n);
        try e.w.writeAll(e.options.vendor);
        try e.w.writeAll(&.{ 0, 0, 0, 0 });
    }

    /// 今の状態の STREAMINFO(`finish` の前は、長さが分かっていればそれ、MD5 とフレームの大きさは不明)
    fn streamInfo(e: *Encoder) [34]u8 {
        const bs: u16 = @intCast(e.fe.preset.block_size);
        const total = if (e.max_frame > 0) e.total else e.options.total_samples orelse 0;
        return streamInfoBytes(.{
            .min_block = bs,
            .max_block = bs,
            .min_frame = if (e.max_frame > 0) e.min_frame else 0,
            .max_frame = e.max_frame,
            .sample_rate = e.options.sample_rate,
            .channels = e.options.channels,
            .bits_per_sample = e.options.bits_per_sample,
            .total = total,
        });
    }

    /// インターリーブした整数(`bits_per_sample` ビットの符号付き)を書く。`samples.len` はチャンネル数の倍数
    pub fn writeI32(e: *Encoder, samples: []const i32) WriteError!void {
        const nch = e.options.channels;
        std.debug.assert(samples.len % nch == 0);
        const frames = samples.len / nch;
        if (e.total + frames > max_total) return error.TooLarge;
        md5Update(&e.md5, e.options.bits_per_sample, samples);
        const bs = e.fe.preset.block_size;
        var i: usize = 0;
        while (i < frames) {
            const n = @min(bs - e.fill, frames - i);
            for (0..n) |j| {
                for (0..nch) |ch| e.block[ch * bs + e.fill + j] = samples[(i + j) * nch + ch];
            }
            e.fill += n;
            i += n;
            if (e.fill == bs) try e.encodeBlock();
        }
        e.total += frames;
    }

    /// インターリーブした f32(満幅 ±1)を、ディザで丸めて書く(`kiln.wav.Encoder` と同じ形の sink)
    pub fn writeF32(e: *Encoder, samples: []const f32) WriteError!void {
        var buf: [4096]i32 = undefined;
        const nch = e.options.channels;
        const per = buf.len / nch * nch;
        var i: usize = 0;
        while (i < samples.len) {
            const n = @min(per, samples.len - i);
            for (samples[i..][0..n], buf[0..n]) |x, *d| d.* = pcm.quantizeBits(&e.q, e.options.bits_per_sample, x);
            try e.writeI32(buf[0..n]);
            i += n;
        }
    }

    /// 残りを書き、STREAMINFO の書き戻しを返す
    pub fn finish(e: *Encoder) Error!StreamInfoPatch {
        if (e.fill > 0) try e.encodeBlock();
        if (e.options.total_samples) |t| if (t != e.total) return error.LengthMismatch;
        var info = e.streamInfo();
        var digest: [16]u8 = undefined;
        e.md5.final(&digest);
        info[18..34].* = digest;
        return .{ .offset = stream_info_offset, .bytes = info };
    }

    fn encodeBlock(e: *Encoder) WriteError!void {
        const n = e.fill;
        const bs = e.fe.preset.block_size;
        var chans: [8][]const i64 = undefined;
        for (0..e.options.channels) |ch| chans[ch] = e.block[ch * bs ..][0..n];
        const bytes = e.fe.encode(chans[0..e.options.channels], e.frame_number, false);
        try e.w.writeAll(bytes);
        const len: u32 = @intCast(bytes.len);
        e.min_frame = @min(e.min_frame, len);
        e.max_frame = @max(e.max_frame, len);
        e.frame_number += 1;
        e.fill = 0;
    }
};

/// MD5 を、サンプルを (ビット深度 + 7) / 8 バイトのリトルエンディアンにしたもので更新する(RFC 9639 §8.2)
pub fn md5Update(md5: *std.crypto.hash.Md5, bits_per_sample: u8, samples: []const i32) void {
    const width = (@as(usize, bits_per_sample) + 7) / 8;
    var buf: [4096]u8 = undefined;
    const per = buf.len / 4;
    var i: usize = 0;
    while (i < samples.len) {
        const n = @min(per, samples.len - i);
        for (samples[i..][0..n], 0..) |v, j| {
            const u: u32 = @bitCast(v);
            for (0..width) |k| buf[j * width + k] = @truncate(u >> @intCast(8 * k));
        }
        md5.update(buf[0 .. n * width]);
        i += n;
    }
}

/// STREAMINFO の中身
pub const StreamInfoFields = struct {
    min_block: u16,
    max_block: u16,
    /// フレームの大きさ(0 なら不明)
    min_frame: u32,
    max_frame: u32,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total: u64,
};

/// STREAMINFO の 34 バイト(MD5 は 0)
pub fn streamInfoBytes(f: StreamInfoFields) [34]u8 {
    var b: [34]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], f.min_block, .big);
    std.mem.writeInt(u16, b[2..4], f.max_block, .big);
    std.mem.writeInt(u24, b[4..7], @intCast(@min(f.min_frame, max_u24)), .big);
    std.mem.writeInt(u24, b[7..10], @intCast(@min(f.max_frame, max_u24)), .big);
    const v: u64 = (@as(u64, f.sample_rate) << 44) |
        (@as(u64, f.channels - 1) << 41) |
        (@as(u64, f.bits_per_sample - 1) << 36) | f.total;
    std.mem.writeInt(u64, b[10..18], v, .big);
    return b;
}

/// 1 フレームの符号化(ストリームのヘッダや MD5 は扱わない)。`Encoder` と FLAC の切り出しが使う
pub const FrameEncoder = struct {
    gpa: std.mem.Allocator,
    preset: Preset,
    channels: u8,
    bits_per_sample: u8,
    sample_rate: u32,
    /// 0..3: ステレオでは左・右・side・mid、それ以外は 0 だけを使い回す
    slots: [4]Slot,
    windows: []f64,
    /// `windows` を作ったときのブロック長(長さの違うブロックで作り直す)
    windows_n: usize = 0,
    wbuf: []f64,
    out: []u8,

    pub const Params = struct {
        sample_rate: u32,
        channels: u8,
        bits_per_sample: u8,
        compression: u8,
    };

    /// `max_block` は符号化するブロックの最大の長さ(null なら段階のブロック長)。65535 まで
    pub fn init(gpa: std.mem.Allocator, params: Params, max_block: ?u32) error{ InvalidOptions, OutOfMemory }!FrameEncoder {
        if (params.channels < 1 or params.channels > 8) return error.InvalidOptions;
        if (params.bits_per_sample < 4 or params.bits_per_sample > 32) return error.InvalidOptions;
        if (params.sample_rate == 0 or params.sample_rate >= 1 << 20) return error.InvalidOptions;
        if (params.compression > max_compression) return error.InvalidOptions;
        const preset = presets[params.compression];
        const cap: usize = max_block orelse preset.block_size;
        if (cap == 0 or cap > 65535) return error.InvalidOptions;
        var e: FrameEncoder = .{
            .gpa = gpa,
            .preset = preset,
            .channels = params.channels,
            .bits_per_sample = params.bits_per_sample,
            .sample_rate = params.sample_rate,
            .slots = undefined,
            .windows = &.{},
            .wbuf = &.{},
            .out = &.{},
        };
        for (&e.slots) |*s| s.* = .{ .sig = &.{}, .res = .{ &.{}, &.{} } };
        errdefer e.deinit();
        // 相関除去を試すときだけ、左・右・side・mid の 4 つを使う
        const nslots: usize = if (params.channels == 2 and preset.stereo != .independent) 4 else 1;
        for (e.slots[0..nslots]) |*s| {
            s.sig = try gpa.alloc(i64, cap);
            s.res = .{ try gpa.alloc(i64, cap), try gpa.alloc(i64, cap) };
        }
        if (preset.max_lpc_order > 0) {
            e.windows = try gpa.alloc(f64, lpc.windowCount(preset.subdivide) * cap);
            e.wbuf = try gpa.alloc(f64, cap);
        }
        e.out = try gpa.alloc(u8, maxFrameLen(@intCast(cap), params.bits_per_sample, params.channels));
        return e;
    }

    pub fn deinit(e: *FrameEncoder) void {
        const gpa = e.gpa;
        for (&e.slots) |*s| {
            gpa.free(s.sig);
            gpa.free(s.res[0]);
            gpa.free(s.res[1]);
        }
        gpa.free(e.windows);
        gpa.free(e.wbuf);
        gpa.free(e.out);
        e.* = undefined;
    }

    /// チャンネルごとのサンプル `chans`(どれも同じ長さ n、1 <= n <= max_block)を 1 フレームに符号化し、
    /// フレームのバイト列(次の呼び出しまで有効)を返す。`variable` なら可変ブロック長のヘッダで、
    /// `number` はサンプル位置。そうでなければ固定ブロック長のヘッダで、`number` はフレーム番号
    pub fn encode(e: *FrameEncoder, chans: []const []const i64, number: u64, variable: bool) []const u8 {
        const n = chans[0].len;
        const nch = e.channels;
        const b: u6 = @intCast(e.bits_per_sample);
        var bw: bits.Writer = .{ .buf = e.out };
        if (nch == 2 and e.preset.stereo != .independent) {
            const l = chans[0];
            const r = chans[1];
            // side(左 - 右)と mid((左 + 右) >> 1)。side は 1 ビット多い
            const side = e.slots[2].res[0][0..n];
            const mid = e.slots[3].res[1][0..n];
            for (l, r, side, mid) |lv, rv, *s, *m| {
                s.* = lv - rv;
                m.* = (lv + rv) >> 1;
            }
            // side と mid は、それぞれのスロットの残差の作業領域に置く(encodeSignal は最初に sig に写すので、
            // その後で上書きされてよい。ほかのスロットの作業領域には触れない)
            const assignment = switch (e.preset.stereo) {
                .exhaustive => blk: {
                    e.encodeSignal(0, l, b);
                    e.encodeSignal(1, r, b);
                    e.encodeSignal(2, side, b + 1);
                    e.encodeSignal(3, mid, b);
                    break :blk bestAssignment(.{ e.slots[0].plan.bits, e.slots[1].plan.bits, e.slots[2].plan.bits, e.slots[3].plan.bits });
                },
                else => blk: {
                    const a = bestAssignment(.{ fixedCost(l), fixedCost(r), fixedCost(side), fixedCost(mid) });
                    const need = assignmentSlots(a);
                    const sigs = [4][]const i64{ l, r, side, mid };
                    for (need) |slot| e.encodeSignal(slot, sigs[slot], if (slot == 2) b + 1 else b);
                    break :blk a;
                },
            };
            e.writeFrameHeader(&bw, n, assignment, number, variable);
            for (assignmentSlots(assignment)) |slot| e.writeSubframe(&bw, slot, n);
        } else {
            e.writeFrameHeader(&bw, n, .independent, number, variable);
            for (chans) |c| {
                e.encodeSignal(0, c, b);
                e.writeSubframe(&bw, 0, n);
            }
        }
        bw.alignByte();
        const crc = frame.Crc16.hash(bw.written());
        bw.put(crc, 16);
        return bw.written();
    }

    fn writeFrameHeader(e: *FrameEncoder, bw: *bits.Writer, n: usize, assignment: frame.Assignment, number: u64, variable: bool) void {
        const start = bw.len;
        bw.put(if (variable) 0xFFF9 else 0xFFF8, 16);
        const bs_code = blockSizeCode(n);
        const sr_code = sampleRateCode(e.sample_rate);
        bw.put(bs_code, 4);
        bw.put(sr_code, 4);
        const ch_code: u64 = switch (assignment) {
            .independent => e.channels - 1,
            .left_side => 8,
            .side_right => 9,
            .mid_side => 10,
        };
        bw.put(ch_code, 4);
        bw.put(bitsCode(e.bits_per_sample), 3);
        bw.put(0, 1);
        putCodedNumber(bw, number);
        if (bs_code == 6) bw.put(n - 1, 8) else if (bs_code == 7) bw.put(n - 1, 16);
        const sr = e.sample_rate;
        switch (sr_code) {
            12 => bw.put(sr / 1000, 8),
            13 => bw.put(sr, 16),
            14 => bw.put(sr / 10, 16),
            else => {},
        }
        bw.put(frame.Crc8.hash(bw.buf[start..bw.len]), 8);
    }

    /// 信号 `x`(`bps` ビット)の最も小さい符号化の方法を `slots[slot].plan` に求める
    fn encodeSignal(e: *FrameEncoder, slot: usize, x: []const i64, bps: u6) void {
        const s = &e.slots[slot];
        const n = x.len;
        var p: Plan = .{};
        // 無駄ビット
        var all: u64 = 0;
        for (x) |v| all |= @bitCast(v);
        p.wasted = if (all == 0) 0 else @intCast(@min(@ctz(all), bps - 1));
        p.bps = bps - p.wasted;
        const sig = s.sig[0..n];
        for (x, sig) |v, *d| d.* = v >> p.wasted;
        const head: u64 = 8 + @as(u64, p.wasted);

        // 定数
        if (std.mem.allEqual(i64, sig, sig[0])) {
            p.kind = .constant;
            p.bits = head + p.bps;
            s.plan = p;
            return;
        }
        // 無圧縮
        p.kind = .verbatim;
        p.bits = head + @as(u64, n) * p.bps;
        var best = p;

        // 固定予測
        const fixed_order = bestFixedOrder(sig);
        {
            var c = p;
            c.kind = .fixed;
            c.order = fixed_order;
            c.res = 1 - best.res;
            const res = s.res[c.res][0 .. n - c.order];
            // 残差が 32 ビットに収まらなければ(32bit の音声や 33 ビットの side で起きうる)使わない
            if (fixedResidual(sig, c.order, res)) {
                if (e.ricePlan(&c, res, n)) |rb| {
                    c.bits = head + @as(u64, c.order) * c.bps + rb;
                    if (c.bits < best.bits) best = c;
                }
            }
        }

        // 線形予測
        const max_order = @min(@as(usize, e.preset.max_lpc_order), n - 1);
        if (max_order > 0) {
            if (e.windows_n != n) {
                lpc.makeWindows(e.windows, n, e.preset.subdivide);
                e.windows_n = n;
            }
            var autoc: [lpc.max_order + 1]f64 = undefined;
            var coefs: [lpc.max_order][lpc.max_order]f64 = undefined;
            var errors: [lpc.max_order]f64 = undefined;
            const base_precision = qlpPrecision(e.bits_per_sample, @intCast(n));
            for (0..lpc.windowCount(e.preset.subdivide)) |wi| {
                lpc.autocorrelation(sig, e.windows[wi * n ..][0..n], e.wbuf, autoc[0 .. max_order + 1]);
                if (autoc[0] <= 0) continue;
                const got = lpc.levinson(autoc[0 .. max_order + 1], max_order, &coefs, &errors);
                // 次数 1 から不安定なら係数がない(自己相関の性質から起きないはずだが、念のため)
                if (got == 0) continue;
                const order = lpc.bestOrder(errors[0..got], n, @floatFromInt(@as(u32, p.bps) + base_precision));
                var precision: u32 = base_precision;
                // 32 ビットの整数で予測を計算するデコーダでもあふれないように(libFLAC と同じ)
                if (p.bps <= 17) {
                    const limit = 32 - @as(i32, p.bps) - @as(i32, std.math.log2_int(usize, order));
                    if (limit < 5) continue;
                    precision = @min(precision, @as(u32, @intCast(limit)));
                }
                var c = p;
                c.kind = .lpc;
                c.order = @intCast(order);
                c.precision = @intCast(precision);
                c.shift = lpc.quantize(coefs[order - 1][0..order], c.precision, c.coefs[0..order]) orelse continue;
                c.res = 1 - best.res;
                const res = s.res[c.res][0 .. n - order];
                if (!lpcResidual(sig, c.coefs[0..order], c.shift, res)) continue;
                const rb = e.ricePlan(&c, res, n) orelse continue;
                c.bits = head + @as(u64, order) * c.bps + 4 + 5 + @as(u64, order) * precision + rb;
                if (c.bits < best.bits) best = c;
            }
        }
        s.plan = best;
    }

    /// 残差 `res`(長さ n - order)の Rice 符号の分割とパラメータを決め、残差の部分のビット数を返す
    fn ricePlan(e: *FrameEncoder, p: *Plan, res: []const i64, n: usize) ?u64 {
        const order = p.order;
        // 分割数でブロック長が割り切れ、最初の分割に予測の次数より多いサンプルが入る最大の次数
        var maxp: u4 = @intCast(@min(@as(usize, e.preset.max_porder), @ctz(n)));
        while (maxp > 0 and (n >> maxp) <= order) maxp -= 1;
        var sums: [1 << max_porder_limit]u64 = undefined;
        const parts_max = @as(usize, 1) << maxp;
        {
            var i: usize = 0;
            for (0..parts_max) |part| {
                const cnt = (n >> maxp) - (if (part == 0) order else 0);
                var sum: u64 = 0;
                for (res[i..][0..cnt]) |r| sum += zigzag(r);
                sums[part] = sum;
                i += cnt;
            }
        }
        var best_bits: u64 = std.math.maxInt(u64);
        var porder: u4 = maxp;
        while (true) {
            const parts = @as(usize, 1) << porder;
            var total: u64 = 0;
            var params: [1 << max_porder_limit]u5 = undefined;
            var wide = false;
            for (0..parts) |part| {
                const cnt = (n >> porder) - (if (part == 0) order else 0);
                const k = riceParam(sums[part], cnt);
                params[part] = k;
                if (k > 14) wide = true;
                total += riceEstimate(sums[part], cnt, k);
            }
            total += parts * @as(u64, if (wide) 5 else 4);
            if (total <= best_bits) {
                best_bits = total;
                p.porder = porder;
                p.param_bits = if (wide) 5 else 4;
                @memcpy(p.params[0..parts], params[0..parts]);
            }
            if (porder == 0) break;
            // 隣り合う分割をまとめて、1 つ低い次数の和にする
            for (0..parts / 2) |part| sums[part] = sums[2 * part] + sums[2 * part + 1];
            porder -= 1;
        }
        // 選んだ分割で、パラメータを前後 1 つずつ正確なビット数で比べて決め直す
        var exact: u64 = 2 + 4;
        const parts = @as(usize, 1) << p.porder;
        var wide = false;
        var i: usize = 0;
        for (0..parts) |part| {
            const cnt = (n >> p.porder) - (if (part == 0) order else 0);
            const k0 = p.params[part];
            const lo: u5 = if (k0 > 0) k0 - 1 else 0;
            const hi: u5 = @min(k0 + 1, 30);
            var acc: [3]u64 = @splat(0);
            for (res[i..][0..cnt]) |r| {
                const u = zigzag(r);
                acc[0] += u >> lo;
                acc[1] += u >> k0;
                acc[2] += u >> hi;
            }
            const ks = [3]u5{ lo, k0, hi };
            var best: usize = 1;
            for (0..3) |c| {
                const bits_c = acc[c] + @as(u64, cnt) * (1 + @as(u64, ks[c]));
                const bits_b = acc[best] + @as(u64, cnt) * (1 + @as(u64, ks[best]));
                if (bits_c < bits_b) best = c;
            }
            p.params[part] = ks[best];
            if (ks[best] > 14) wide = true;
            exact += acc[best] + @as(u64, cnt) * (1 + @as(u64, ks[best]));
            i += cnt;
        }
        p.param_bits = if (wide) 5 else 4;
        exact += parts * @as(u64, p.param_bits);
        return exact;
    }

    fn writeSubframe(e: *FrameEncoder, bw: *bits.Writer, slot: usize, n: usize) void {
        const s = &e.slots[slot];
        const p = &s.plan;
        const sig = s.sig[0..n];
        bw.put(0, 1);
        const kind: u64 = switch (p.kind) {
            .constant => 0,
            .verbatim => 1,
            .fixed => 8 + @as(u64, p.order),
            .lpc => 32 + @as(u64, p.order) - 1,
        };
        bw.put(kind, 6);
        if (p.wasted > 0) {
            bw.put(1, 1);
            bw.putUnary(p.wasted - 1);
        } else bw.put(0, 1);
        switch (p.kind) {
            .constant => bw.putSigned(sig[0], p.bps),
            .verbatim => for (sig) |v| bw.putSigned(v, p.bps),
            .fixed, .lpc => {
                for (sig[0..p.order]) |v| bw.putSigned(v, p.bps);
                if (p.kind == .lpc) {
                    bw.put(p.precision - 1, 4);
                    bw.put(p.shift, 5);
                    for (p.coefs[0..p.order]) |c| bw.putSigned(c, p.precision);
                }
                writeResidual(bw, p, s.res[p.res][0 .. n - p.order], n);
            },
        }
    }
};

fn writeResidual(bw: *bits.Writer, p: *const Plan, res: []const i64, n: usize) void {
    bw.put(if (p.param_bits == 5) 1 else 0, 2);
    bw.put(p.porder, 4);
    const parts = @as(usize, 1) << p.porder;
    var i: usize = 0;
    for (0..parts) |part| {
        const cnt = (n >> p.porder) - (if (part == 0) p.order else 0);
        const k: u6 = p.params[part];
        bw.put(k, p.param_bits);
        const mask = (@as(u64, 1) << k) - 1;
        for (res[i..][0..cnt]) |r| {
            const u = zigzag(r);
            bw.putUnary(u >> k);
            bw.put(u & mask, k);
        }
        i += cnt;
    }
}

inline fn zigzag(r: i64) u64 {
    return @bitCast((r << 1) ^ (r >> 63));
}

/// 和 `sum`(zigzag にした残差の和)、サンプル数 `cnt` の分割の Rice 符号の見積もりのビット数
fn riceEstimate(sum: u64, cnt: usize, k: u5) u64 {
    return @as(u64, cnt) * (1 + @as(u64, k)) + (sum >> k);
}

/// 和 `sum`、サンプル数 `cnt` の分割に使う Rice 符号のパラメータ。見積もりのビット数が最小のもの
/// (およそ 2^k = 平均 × ln 2)
fn riceParam(sum: u64, cnt: usize) u5 {
    if (cnt == 0 or sum == 0) return 0;
    var best: u5 = 0;
    var best_bits = riceEstimate(sum, cnt, 0);
    var k: u5 = 1;
    while (k <= 30) : (k += 1) {
        const b = riceEstimate(sum, cnt, k);
        if (b < best_bits) {
            best_bits = b;
            best = k;
        } else if (b > best_bits) break;
    }
    return best;
}

/// 固定予測の次数 0〜4 のうち、残差の絶対値の和が最小のもの
fn bestFixedOrder(x: []const i64) u8 {
    const max_o: usize = @min(4, x.len - 1);
    // 短いブロックは見積もりができないので、次数 1(長さ 1 なら 0)にする
    if (x.len <= 4) return @intCast(@min(max_o, 1));
    var sums: [5]u64 = @splat(0);
    for (4..x.len) |i| {
        const d0 = x[i];
        const d1 = d0 - x[i - 1];
        const d2 = d1 - (x[i - 1] - x[i - 2]);
        const d3 = d2 - ((x[i - 1] - x[i - 2]) - (x[i - 2] - x[i - 3]));
        const d4 = d3 - (((x[i - 1] - x[i - 2]) - (x[i - 2] - x[i - 3])) - ((x[i - 2] - x[i - 3]) - (x[i - 3] - x[i - 4])));
        sums[0] += @abs(d0);
        sums[1] += @abs(d1);
        sums[2] += @abs(d2);
        sums[3] += @abs(d3);
        sums[4] += @abs(d4);
    }
    var best: u8 = 0;
    for (1..max_o + 1) |o| {
        if (sums[o] < sums[best]) best = @intCast(o);
    }
    return best;
}

/// 固定予測の見積もりのコスト(ステレオの方式を選ぶのに使う)
fn fixedCost(x: []const i64) u64 {
    if (x.len < 5) return 0;
    var sums: [5]u64 = @splat(0);
    for (4..x.len) |i| {
        const d1 = x[i] - x[i - 1];
        const d2 = d1 - (x[i - 1] - x[i - 2]);
        sums[0] += @abs(x[i]);
        sums[1] += @abs(d1);
        sums[2] += @abs(d2);
    }
    return @min(sums[0], @min(sums[1], sums[2]));
}

/// 固定予測の残差。残差が 32 ビットに収まらなければ false
fn fixedResidual(x: []const i64, order: u8, res: []i64) bool {
    for (order..x.len, res) |i, *r| {
        const v = x[i] - switch (order) {
            0 => 0,
            1 => x[i - 1],
            2 => 2 * x[i - 1] - x[i - 2],
            3 => 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3],
            4 => 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4],
            else => unreachable,
        };
        if (v > max_residual or v < -max_residual) return false;
        r.* = v;
    }
    return true;
}

/// 線形予測の残差。残差が 32 ビットに収まらなければ false
fn lpcResidual(x: []const i64, coefs: []const i32, shift: u5, res: []i64) bool {
    const order = coefs.len;
    for (order..x.len, res) |i, *r| {
        var sum: i64 = 0;
        for (coefs, 1..) |c, j| sum += @as(i64, c) * x[i - j];
        const v = x[i] - (sum >> shift);
        if (v > max_residual or v < -max_residual) return false;
        r.* = v;
    }
    return true;
}

/// 相関除去の方式のうち、4 つの信号(左・右・side・mid)の大きさの和が最小のもの
fn bestAssignment(cost: [4]u64) frame.Assignment {
    const options = [_]struct { a: frame.Assignment, c: u64 }{
        .{ .a = .independent, .c = cost[0] +| cost[1] },
        .{ .a = .left_side, .c = cost[0] +| cost[2] },
        .{ .a = .side_right, .c = cost[2] +| cost[1] },
        .{ .a = .mid_side, .c = cost[3] +| cost[2] },
    };
    var best = options[0];
    for (options[1..]) |o| if (o.c < best.c) {
        best = o;
    };
    return best.a;
}

/// 方式ごとに書くサブフレームのスロット(書く順)
fn assignmentSlots(a: frame.Assignment) [2]usize {
    return switch (a) {
        .independent => .{ 0, 1 },
        .left_side => .{ 0, 2 },
        .side_right => .{ 2, 1 },
        .mid_side => .{ 3, 2 },
    };
}

/// LPC の係数のビット数(libFLAC の既定と同じ。ビット深度とブロック長で決める)
fn qlpPrecision(bps: u8, block_size: u32) u32 {
    if (bps < 16) return @max(5, 2 + @as(u32, bps) / 2);
    if (bps == 16) {
        if (block_size <= 192) return 7;
        if (block_size <= 384) return 8;
        if (block_size <= 576) return 9;
        if (block_size <= 1152) return 10;
        if (block_size <= 2304) return 11;
        if (block_size <= 4608) return 12;
        return 13;
    }
    if (block_size <= 384) return 13;
    if (block_size <= 1152) return 14;
    return 15;
}

const max_u24 = (1 << 24) - 1;

/// フレームの大きさの上限(すべて無圧縮のときに余裕を足したもの。どの方法も無圧縮以下を選ぶ)
fn maxFrameLen(block_size: u32, bps: u8, channels: u8) usize {
    const per_channel = (@as(usize, block_size) * (bps + 1) + 8 + 40) / 8 + 1;
    return 18 + per_channel * channels + 2 + 8;
}

fn blockSizeCode(n: usize) u64 {
    if (n == 192) return 1;
    for (0..4) |k| if (n == @as(usize, 576) << @intCast(k)) return 2 + k;
    for (0..8) |k| if (n == @as(usize, 256) << @intCast(k)) return 8 + k;
    return if (n <= 256) 6 else 7;
}

fn sampleRateCode(sr: u32) u64 {
    return switch (sr) {
        88200 => 1,
        176400 => 2,
        192000 => 3,
        8000 => 4,
        16000 => 5,
        22050 => 6,
        24000 => 7,
        32000 => 8,
        44100 => 9,
        48000 => 10,
        96000 => 11,
        else => if (sr % 1000 == 0 and sr / 1000 <= 255)
            12
        else if (sr <= 65535)
            13
        else if (sr % 10 == 0 and sr / 10 <= 65535)
            14
        else
            0,
    };
}

fn bitsCode(b: u8) u64 {
    return switch (b) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        32 => 7,
        else => 0,
    };
}

/// フレーム番号(またはサンプル位置)を可変長の符号(UTF-8 に似たもの)で書く
pub fn putCodedNumber(bw: *bits.Writer, v: u64) void {
    if (v < 0x80) return bw.put(v, 8);
    // バイト数ごとに書けるビット数(2 バイトなら 5 + 6 …)
    const caps = [_]u6{ 7, 11, 16, 21, 26, 31, 36 };
    var len: usize = 1;
    while (v >> caps[len - 1] != 0) len += 1;
    const cont: u6 = @intCast(len - 1);
    const lead: u8 = @truncate(@as(u16, 0xFF00) >> @intCast(len));
    bw.put(lead | (v >> (6 * cont)), 8);
    var k = cont;
    while (k > 0) {
        k -= 1;
        bw.put(0x80 | ((v >> (6 * k)) & 0x3F), 8);
    }
}
