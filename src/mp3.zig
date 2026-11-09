// SPDX-License-Identifier: MIT
//! MP3(MPEG-1 Layer III)の解析と、無劣化・サンプル精度のトリム。
//!
//! 位置はすべて「タイムライン」上のサンプル位置で表す。タイムラインは ffmpeg がデコードした
//! ときの先頭を 0 とする位置で、LAME タグ付きの入力では元のエンコーダ遅延を除いた位置、
//! タグなしの入力ではデコーダ出力そのままの位置になる。
const std = @import("std");
const Io = std.Io;
const frame = @import("mp3/frame.zig");
const stream = @import("mp3/stream.zig");
const trim_impl = @import("mp3/trim.zig");
const decoder = @import("mp3/decoder.zig");
const layer3 = @import("mp3/layer3.zig");
const pcm = @import("pcm.zig");
const wav = @import("wav.zig");

/// 1 フレームずつ復号するデコーダ(低レベル API)
pub const Decoder = decoder.Decoder;

/// 1 フレームあたりのサンプル数
pub const samples_per_frame = frame.samples_per_frame;

pub const ParseError = stream.Error;
pub const TrimOptions = trim_impl.Options;
pub const TrimResult = trim_impl.Result;
pub const TrimError = trim_impl.Error;

pub const Info = struct {
    sample_rate: u32,
    channels: u8,
    /// タイムラインの長さ(サンプル数)
    samples: u64,
    /// 音声フレームの数(Xing / Info / VBRI のフレームは含めない)
    frames: u64,
    /// トリムで指定できる先頭の最小値。タグなしの入力では、デコーダ遅延の 529 サンプルは
    /// 再現できないため 529、LAME タグ付きの入力では 0
    min_start: u64,
};

/// 入力全体を解析して、サンプルレートや長さを返す
pub fn probe(input: []const u8) ParseError!Info {
    const s = try stream.Stream.parse(input);
    return .{
        .sample_rate = s.header.sampleRate(),
        .channels = s.header.channels(),
        .samples = s.samples,
        .frames = s.frames,
        .min_start = stream.decoder_delay -| s.skip,
    };
}

/// 区間 `[options.start, options.end)` を再エンコードせずに切り出し、`w` に書く。
/// 範囲外の指定は丸め、実際に切り出した区間(と入力のサンプルレート)を返す。`w.flush()` は呼び出し側が行う。
/// 出力の構成は docs/lyria-mp3.md §4
pub const trim = trim_impl.trim;

pub const Trimmed = struct {
    data: []u8,
    start: u64,
    end: u64,
    sample_rate: u32,
};

/// `trim` の一括版。返した `data` は呼び出し側が `gpa` で解放する
pub fn trimAlloc(
    gpa: std.mem.Allocator,
    input: []const u8,
    options: TrimOptions,
) (error{OutOfMemory} || ParseError || error{ EmptyRange, TooLarge })!Trimmed {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const r = trim(input, options, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return .{ .data = try out.toOwnedSlice(), .start = r.start, .end = r.end, .sample_rate = r.sample_rate };
}

pub const DecodeOptions = struct {
    /// 区間の先頭(タイムライン上のサンプル位置)
    start: u64 = 0,
    /// 区間の終わり(この位置は含まない)。null なら末尾まで
    end: ?u64 = null,
};

pub const DecodeResult = struct {
    /// 実際にデコードした区間(範囲外の指定を丸めた後)
    start: u64,
    end: u64,
    sample_rate: u32,
    channels: u8,
    /// 復号できなかった(サイド情報が壊れていた)フレームの数。そのフレームは無音
    /// (前のフレームの重ね合わせの残り)になっている
    invalid_frames: u64,
};

/// 入力全体を解析し、タイムライン上の区間 `[options.start, options.end)` の PCM を、
/// チャンネルをインターリーブした f32 で `sink.writeF32(samples)` に渡す(`kiln.wav.Encoder` をそのまま渡せる)。
/// 末尾は入力の長さで切り詰める。復号は区間の少し手前のフレームから始める(結果は先頭から復号したときと同じ)
pub fn decode(input: []const u8, options: DecodeOptions, sink: anytype) !DecodeResult {
    const s = try stream.Stream.parse(input);
    const range = try clampDecodeRange(&s, options);
    return decodeParsed(input, &s, range, sink);
}

pub const WavOptions = struct {
    /// 書き出すサンプル形式
    format: pcm.Format = .i16,
    /// 整数形式で書くときのディザ
    dither: pcm.Dither = .tpdf,
};

/// `decode` した区間を WAV にして `w` に書く(入力の解析は 1 回)。`w.flush()` は呼び出し側が行う
pub fn toWav(input: []const u8, options: DecodeOptions, wav_options: WavOptions, w: *Io.Writer) !DecodeResult {
    const s = try stream.Stream.parse(input);
    const range = try clampDecodeRange(&s, options);
    var enc: wav.Encoder = try .init(w, .{
        .sample_rate = s.header.sampleRate(),
        .channels = s.header.channels(),
        .format = wav_options.format,
        .dither = wav_options.dither,
        .frames = range.end - range.start,
    });
    const r = try decodeParsed(input, &s, range, &enc);
    _ = try enc.finish();
    return r;
}

const Range = struct { start: u64, end: u64 };

/// デコードの区間を丸める(末尾は入力の長さまで。先頭は切り上げない)
fn clampDecodeRange(s: *const stream.Stream, options: DecodeOptions) error{EmptyRange}!Range {
    const end = @min(options.end orelse s.samples, s.samples);
    if (options.start >= end) return error.EmptyRange;
    return .{ .start = options.start, .end = end };
}

/// 復号を始めるのに十分なメインデータのバイト数(ビットリザーバの上限)
const reservoir_bytes = 512;

fn decodeParsed(input: []const u8, s: *const stream.Stream, range: Range, sink: anytype) !DecodeResult {
    const nch = s.header.channels();
    // デコーダ出力上の位置 [a, b)
    const a = range.start + s.skip;
    const b = range.end + s.skip;
    const first = startFrame(s, a / samples_per_frame);

    var d: Decoder = .{};
    var out: [2][1152]f32 = undefined;
    var inter: [2 * 1152]f32 = undefined;
    var invalid: u64 = 0;
    var it = s.iterator();
    var index: u64 = 0;
    while (it.next()) |f| : (index += 1) {
        const p = index * samples_per_frame;
        if (p >= b) break;
        if (index < first) continue;
        const bad = if (d.decodeFrame(f.bytes(input), &out)) |_| false else |_| true;
        const lo = @max(a, p);
        const hi = @min(b, p + samples_per_frame);
        if (lo >= hi) continue;
        if (bad) invalid += 1;
        const n: usize = @intCast(hi - lo);
        const off: usize = @intCast(lo - p);
        for (0..n) |i| {
            for (0..nch) |ch| inter[i * nch + ch] = out[ch][off + i];
        }
        try sink.writeF32(inter[0 .. n * nch]);
    }
    return .{
        .start = range.start,
        .end = range.end,
        .sample_rate = s.header.sampleRate(),
        .channels = nch,
        .invalid_frames = invalid,
    };
}

/// フレーム `k` を正しく復号するために、復号を始めるフレーム。
/// フレーム k は、1 つ前のフレーム(IMDCT の重ね合わせと合成フィルタの状態)が正しければ正しく、
/// 1 つ前のフレームは、ビットリザーバがそろっていれば正しい。リザーバ(最大 512 バイト)がそろうよう、
/// k - 2 から遡ってメインデータの合計が 512 バイト以上になるフレームから始める
fn startFrame(s: *const stream.Stream, k: u64) u64 {
    if (k < 2) return 0;
    // k - 2 から遡るので、それまでのフレームのメインデータの長さを直近の分だけ覚えておく
    // (MPEG-1 のフレームのメインデータは 60 バイト以上なので、16 フレームあれば 512 バイトを超える)
    var lens: [16]usize = @splat(0);
    var it = s.iterator();
    var index: u64 = 0;
    while (index < k - 1) : (index += 1) {
        const f = it.next() orelse break;
        const h = f.header;
        const side: usize = 4 + @as(usize, if (h.hasCrc()) 2 else 0) + layer3.sideInfoLen(h.channels());
        lens[@intCast(index % lens.len)] = h.frameLen() -| side;
    }
    var total: usize = 0;
    var j = k - 1;
    while (j > 0 and k - 1 - j < lens.len and total < reservoir_bytes) {
        j -= 1;
        total += lens[@intCast(j % lens.len)];
    }
    return j;
}

test {
    _ = frame;
    _ = stream;
    _ = trim_impl;
    _ = @import("mp3/id3.zig");
    _ = @import("mp3/xing.zig");
    _ = @import("mp3/bits.zig");
    _ = @import("mp3/huffman.zig");
    _ = @import("mp3/layer3.zig");
    _ = @import("mp3/synth.zig");
    _ = decoder;
}

const testdata = @import("testdata");

test probe {
    const lyria = try probe(testdata.lyria_like);
    try std.testing.expectEqual(Info{ .sample_rate = 44100, .channels = 2, .samples = 78 * 1152, .frames = 78, .min_start = 529 }, lyria);
    const lame = try probe(testdata.cbr128_lame);
    try std.testing.expectEqual(88200, lame.samples);
    try std.testing.expectEqual(0, lame.min_start);
    const mono = try probe(testdata.mono48k_notag);
    try std.testing.expectEqual(48000, mono.sample_rate);
    try std.testing.expectEqual(1, mono.channels);
}

test trimAlloc {
    const t = try trimAlloc(std.testing.allocator, testdata.lyria_like, .{ .start = 0, .end = 44100 });
    defer std.testing.allocator.free(t.data);
    try std.testing.expectEqual(529, t.start);
    try std.testing.expectEqual(44100, t.end);
    try std.testing.expectEqual(44100, t.sample_rate);
    try std.testing.expectEqual(44100 - 529, (try probe(t.data)).samples);
}

/// テスト用: 受け取ったサンプルを数え、最大振幅を記録する
const CountingSink = struct {
    n: usize = 0,
    peak: f32 = 0,
    finite: bool = true,

    pub fn writeF32(s: *CountingSink, samples: []const f32) !void {
        s.n += samples.len;
        for (samples) |v| {
            if (!std.math.isFinite(v)) s.finite = false;
            s.peak = @max(s.peak, @abs(v));
        }
    }
};

/// テスト用: 受け取ったサンプルをためる
const CollectSink = struct {
    list: std.ArrayList(f32) = .empty,

    pub fn writeF32(c: *CollectSink, samples: []const f32) !void {
        try c.list.appendSlice(std.testing.allocator, samples);
    }
};

test "decode: 区間の手前から復号しても、先頭から復号したときと同じ" {
    for ([_][]const u8{ testdata.lyria_like, testdata.cbr128_lame, testdata.vbr_lame, testdata.mono48k_notag }) |in| {
        var all: CollectSink = .{};
        defer all.list.deinit(std.testing.allocator);
        const full = try decode(in, .{}, &all);
        const nch = full.channels;
        for ([_]u64{ 1, 1151, 1152, 1153, 3 * 1152 + 77, 10 * 1152, 20 * 1152 + 500, full.end - 1 }) |start| {
            var part: CollectSink = .{};
            defer part.list.deinit(std.testing.allocator);
            _ = try decode(in, .{ .start = start }, &part);
            try std.testing.expectEqualSlices(f32, all.list.items[@intCast(start * nch)..], part.list.items);
        }
    }
}

test toWav {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const r = try toWav(testdata.lyria_like, .{ .start = 100, .end = 1100 }, .{ .format = .f32 }, &out.writer);
    try std.testing.expectEqual(0, r.invalid_frames);
    const i = try wav.probe(out.written());
    try std.testing.expectEqual(wav.Info{ .sample_rate = 44100, .channels = 2, .format = .f32, .samples = 1000 }, i);
    var discard: Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.EmptyRange, toWav(testdata.lyria_like, .{ .start = 5, .end = 5 }, .{}, &discard.writer));
}

test decode {
    for ([_][]const u8{ testdata.lyria_like, testdata.cbr128_lame, testdata.vbr_lame, testdata.mono48k_notag }) |in| {
        const info = try probe(in);
        var sink: CountingSink = .{};
        const r = try decode(in, .{}, &sink);
        try std.testing.expectEqual(info.samples * info.channels, sink.n);
        try std.testing.expectEqual(info.samples, r.end);
        try std.testing.expect(sink.finite);
        // 合成音の振幅は 0.5 程度(正弦波 0.5 + ノイズ 0.05)
        try std.testing.expect(sink.peak > 0.3 and sink.peak < 0.8);
    }
    var sink: CountingSink = .{};
    const r = try decode(testdata.lyria_like, .{ .start = 1000, .end = 2000 }, &sink);
    try std.testing.expectEqual(2000, sink.n);
    try std.testing.expectEqual(1000, r.start);
    try std.testing.expectError(error.EmptyRange, decode(testdata.lyria_like, .{ .start = 5, .end = 5 }, &sink));
}
