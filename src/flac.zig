// SPDX-License-Identifier: MIT
//! FLAC の解析と復号(設計は docs/flac.md)。
//!
//! 位置はフレーム(チャンネルあたりのサンプル)単位で、最初のフレームの先頭を 0 とする。
//! PCM は可逆のまま扱うため、復号した値は整数(ビット深度 `bits_per_sample` の符号付き整数)で渡す。
const std = @import("std");
const Io = std.Io;
const pcm = @import("pcm.zig");
const wav = @import("wav.zig");
const stream = @import("flac/stream.zig");
const decoder = @import("flac/decoder.zig");
const metadata = @import("flac/metadata.zig");
const encoder = @import("flac/encoder.zig");
const mp3 = @import("mp3.zig");

pub const ParseError = stream.Error;

pub const Info = struct {
    sample_rate: u32,
    channels: u8,
    /// ビット深度(4〜32)
    bits_per_sample: u8,
    /// 長さ(サンプル数)。実際のフレームから数えたもの(壊れて失われたフレームの分を含む)
    samples: u64,
    /// フレームの数
    frames: u64,
    /// STREAMINFO に書かれた、復号した PCM の MD5(すべて 0 なら不明)
    md5: [16]u8,
};

/// 入力全体を解析して、サンプルレートや長さを返す(フレームの区切りもすべて確かめる)
pub fn probe(input: []const u8) ParseError!Info {
    const s = try stream.Stream.parse(input);
    return infoOf(&s);
}

pub const StreamFormat = struct {
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
};

/// メタデータ(STREAMINFO)だけを読み、サンプルレートなどを返す。フレームは見ないので `probe` より軽い
/// (秒をサンプル位置に直すときなどに使う)
pub fn streamFormat(input: []const u8) ParseError!StreamFormat {
    const si = (try metadata.Metadata.parse(input)).info;
    return .{ .sample_rate = si.sample_rate, .channels = si.channels, .bits_per_sample = si.bits };
}

/// 先頭(ID3v2 タグがあればその後)が FLAC の印(`fLaC`、または Ogg FLAC)か。フレームは見ない
/// (`kiln.detect` に使う。壊れたメタデータや Ogg FLAC も true で、詳しいエラーは `probe` で出す)
pub fn hasSignature(input: []const u8) bool {
    _ = metadata.Metadata.parse(input) catch |err| return err != error.NotFlac;
    return true;
}

fn infoOf(s: *const stream.Stream) Info {
    const si = s.info();
    return .{
        .sample_rate = si.sample_rate,
        .channels = si.channels,
        .bits_per_sample = si.bits,
        .samples = s.samples,
        .frames = s.frames,
        .md5 = si.md5,
    };
}

pub const DecodeOptions = struct {
    /// 区間の先頭(サンプル位置)
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
    bits_per_sample: u8,
    /// 復号できなかった(CRC が合わない、中身が壊れている、失われた)フレームの数。その分は無音になっている
    invalid_frames: u64,
};

pub const WavOptions = struct {
    /// 書き出すサンプル形式。null ならビット深度を保つ形式(8bit 以下は u8、16bit 以下は i16、
    /// 24bit 以下は i24、それより多ければ i32。ビット数が足りない分は下位に 0 を足すので可逆)
    format: ?pcm.Format = null,
    /// ビット数を減らすとき(24bit → i16 など)のディザ
    dither: pcm.Dither = .tpdf,
};

/// ビット深度を保つ WAV のサンプル形式
pub fn wavFormat(bits_per_sample: u8) pcm.Format {
    return if (bits_per_sample <= 8) .u8 else if (bits_per_sample <= 16) .i16 else if (bits_per_sample <= 24) .i24 else .i32;
}

/// 解析済みの FLAC(フレームの一覧)。フレームの区切りを探す走査を 1 回で済ませるためのもので、
/// `decode` / `toWav` / `toWavAlloc` は中でこれを作る。入力のスライスを参照する
pub const Index = struct {
    input: []const u8,
    s: stream.Index,

    pub fn init(gpa: std.mem.Allocator, input: []const u8) (ParseError || error{OutOfMemory})!Index {
        return .{ .input = input, .s = try .init(gpa, input) };
    }

    pub fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        ix.s.deinit(gpa);
    }

    pub fn info(ix: *const Index) Info {
        return infoOf(&ix.s.stream);
    }

    /// 区間を丸める(末尾は入力の長さまで)
    fn clamp(ix: *const Index, options: DecodeOptions) error{EmptyRange}!Range {
        const total = ix.s.stream.samples;
        const end = @min(options.end orelse total, total);
        if (options.start >= end) return error.EmptyRange;
        return .{ .start = options.start, .end = end };
    }

    /// `kiln.flac.decode` と同じ。`gpa` は復号の作業領域に使う
    pub fn decode(ix: *const Index, gpa: std.mem.Allocator, options: DecodeOptions, sink: anytype) !DecodeResult {
        return ix.decodeRange(gpa, try ix.clamp(options), sink);
    }

    fn decodeRange(ix: *const Index, gpa: std.mem.Allocator, range: Range, sink: anytype) !DecodeResult {
        const si = ix.s.stream.info();
        const nch: usize = si.channels;
        var d: decoder.Decoder = .init(gpa);
        defer d.deinit();
        var inter: [4096]i32 = undefined;
        const chunk = inter.len / nch;
        var invalid: u64 = 0;
        for (ix.s.frames) |f| {
            if (f.sample >= range.end) break;
            if (f.sample + f.samples <= range.start) continue;
            const samples: ?[]const i64 = if (f.header) |h|
                d.decodeFrame(f.bytes(ix.input), h, if (h.bits != 0) h.bits else si.bits) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidFrame => null,
                }
            else
                null;
            if (samples == null) invalid += f.count;

            // 壊れた区間は長いことがある(wasm32 の usize に収まらないこともある)ので、位置は u64 で数える
            const lo = @max(range.start, f.sample) - f.sample;
            const hi = @min(range.end, f.sample + f.samples) - f.sample;
            var i = lo;
            while (i < hi) {
                const n: usize = @intCast(@min(chunk, hi - i));
                if (samples) |x| {
                    // 復号できたフレームの長さはブロック長(65536 以下)
                    const bs: usize = f.header.?.block_size;
                    const off: usize = @intCast(i);
                    for (0..n) |j| {
                        for (0..nch) |ch| inter[j * nch + ch] = @intCast(x[ch * bs + off + j]);
                    }
                } else {
                    @memset(inter[0 .. n * nch], 0);
                }
                try sink.writeI32(inter[0 .. n * nch]);
                i += n;
            }
        }
        return .{
            .start = range.start,
            .end = range.end,
            .sample_rate = si.sample_rate,
            .channels = si.channels,
            .bits_per_sample = si.bits,
            .invalid_frames = invalid,
        };
    }

    /// `kiln.flac.toWav` と同じ
    pub fn toWav(ix: *const Index, gpa: std.mem.Allocator, options: DecodeOptions, wav_options: WavOptions, w: *Io.Writer) !DecodeResult {
        return ix.toWavRange(gpa, try ix.clamp(options), wav_options, w);
    }

    fn toWavRange(ix: *const Index, gpa: std.mem.Allocator, range: Range, wav_options: WavOptions, w: *Io.Writer) !DecodeResult {
        var enc: wav.Encoder = try .init(w, ix.wavEncoderOptions(range, wav_options));
        const si = ix.s.stream.info();
        const format = wav_options.format orelse wavFormat(si.bits);
        var sink: WavSink = .{ .enc = &enc, .format = format, .bits = si.bits, .q = .init(wav_options.dither) };
        const r = try ix.decodeRange(gpa, range, &sink);
        _ = enc.finish() catch |err| switch (err) {
            // decodeRange は区間のサンプル数ちょうどを書くので、食い違うのは kiln の不具合
            error.LengthMismatch => return error.InternalError,
            else => |e| return e,
        };
        return r;
    }

    fn wavEncoderOptions(ix: *const Index, range: Range, wav_options: WavOptions) wav.EncoderOptions {
        const si = ix.s.stream.info();
        return .{
            .sample_rate = si.sample_rate,
            .channels = si.channels,
            .format = wav_options.format orelse wavFormat(si.bits),
            .dither = wav_options.dither,
            .frames = range.end - range.start,
        };
    }
};

const Range = struct { start: u64, end: u64 };

/// 入力全体を解析し、区間 `[options.start, options.end)` の PCM を、チャンネルをインターリーブした
/// 整数(`bits_per_sample` ビットの符号付き)で `sink.writeI32(samples)` に渡す。末尾は入力の長さで切り詰める。
/// フレームは互いに独立しているので、区間の先頭を含むフレームから復号する。
/// `gpa` はフレームの一覧と、復号の作業領域(チャンネル数 × ブロック長の i64)の確保に使う
pub fn decode(gpa: std.mem.Allocator, input: []const u8, options: DecodeOptions, sink: anytype) !DecodeResult {
    var ix: Index = try .init(gpa, input);
    defer ix.deinit(gpa);
    return ix.decode(gpa, options, sink);
}

/// 復号した整数を WAV のサンプル形式に変換して書く sink
const WavSink = struct {
    enc: *wav.Encoder,
    format: pcm.Format,
    bits: u8,
    q: pcm.Quantizer,

    pub fn writeI32(s: *WavSink, samples: []const i32) !void {
        var buf: [4096]u8 = undefined;
        // writeRaw にはフレーム(全チャンネルのサンプル)単位で渡す
        const frame_len = s.enc.frameLen();
        const per = buf.len / frame_len * (frame_len / s.format.bytes());
        var i: usize = 0;
        while (i < samples.len) {
            const n = @min(per, samples.len - i);
            const out = buf[0 .. n * s.format.bytes()];
            pcm.fromInt(s.format, s.bits, samples[i..][0..n], out, &s.q);
            try s.enc.writeRaw(out);
            i += n;
        }
    }
};

/// `decode` した区間を WAV にして `w` に書く(入力の解析は 1 回)。`w.flush()` は呼び出し側が行う
pub fn toWav(gpa: std.mem.Allocator, input: []const u8, options: DecodeOptions, wav_options: WavOptions, w: *Io.Writer) !DecodeResult {
    var ix: Index = try .init(gpa, input);
    defer ix.deinit(gpa);
    return ix.toWav(gpa, options, wav_options, w);
}

pub const WavDecoded = struct {
    /// WAV ファイル全体。呼び出し側が `gpa` で解放する
    data: []u8,
    result: DecodeResult,
};

/// `toWav` の一括版。出力の大きさを前もって計算して一度に確保する
pub fn toWavAlloc(gpa: std.mem.Allocator, input: []const u8, options: DecodeOptions, wav_options: WavOptions) !WavDecoded {
    var ix: Index = try .init(gpa, input);
    defer ix.deinit(gpa);
    const range = try ix.clamp(options);
    const len = try wav.Encoder.fileLen(ix.wavEncoderOptions(range, wav_options));
    var out = try Io.Writer.Allocating.initCapacity(gpa, std.math.cast(usize, len) orelse return error.TooLarge);
    defer out.deinit();
    const r = ix.toWavRange(gpa, range, wav_options, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    std.debug.assert(out.written().len == len);
    return .{ .data = try out.toOwnedSlice(), .result = r };
}

// --- 書き出し ---

/// ストリーミングのエンコーダ(`init → writeI32 / writeF32 → finish`)。`finish` が返す STREAMINFO を、
/// 呼び出し側が出力の先頭に書き戻す(長さ・MD5・フレームの大きさは最後に決まるため)
pub const Encoder = encoder.Encoder;
pub const EncoderOptions = encoder.Options;
pub const StreamInfoPatch = encoder.StreamInfoPatch;
/// 圧縮の段階の最大値(flac の -8)
pub const max_compression = encoder.max_compression;

/// FLAC に書き出すときの指定(`kiln.flac.encodePlanarAlloc`、`kiln.wav.toFlacAlloc`、`kiln.mp3.toFlacAlloc`)
pub const WriteOptions = struct {
    /// ビット深度(4〜32)。null なら、整数の WAV は元のビット深度、それ以外(浮動小数点)は 16
    bits_per_sample: ?u8 = null,
    /// 圧縮の段階(0〜8。flac の -0〜-8)
    compression: u8 = 5,
    /// 浮動小数点から整数にするとき、整数のビット数を減らすときのディザ
    dither: pcm.Dither = .tpdf,
};

/// ベンダー文字列(Vorbis コメント)
pub const vendor = "kiln " ++ @import("build_options").version;

/// 一括版(`...Alloc`)のエラー
pub const WriteError = error{ OutOfMemory, InvalidOptions, TooLarge, InternalError };
/// `*Io.Writer` に書く版のエラー
pub const StreamError = Io.Writer.Error || WriteError;

/// エンコーダのエラーを、`*Io.Writer` に書く版のエラーにする(書き込みの失敗はそのまま)
pub fn mapStreamError(err: anyerror) StreamError {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidOptions => error.InvalidOptions,
        error.TooLarge => error.TooLarge,
        // 書く長さは入力から決めるので、食い違うのは kiln の不具合
        else => error.InternalError,
    };
}

/// `Io.Writer.Allocating` に書いた FLAC の先頭に STREAMINFO を書き戻し、バイト列として引き取る
pub fn takePatched(out: *Io.Writer.Allocating, patch: StreamInfoPatch) error{OutOfMemory}![]u8 {
    const data = try out.toOwnedSlice();
    @memcpy(data[patch.offset..][0..patch.bytes.len], &patch.bytes);
    return data;
}

/// `Io.Writer.Allocating` に書いたエンコーダを閉じ、STREAMINFO を書き戻したバイト列を返す
pub fn finishAlloc(enc: *Encoder, out: *Io.Writer.Allocating) WriteError![]u8 {
    const patch = enc.finish() catch |err| return mapWriteError(err);
    return takePatched(out, patch);
}

/// エンコーダのエラーを一括版のエラーにする
pub fn mapWriteError(err: anyerror) WriteError {
    return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        error.InvalidOptions => error.InvalidOptions,
        error.TooLarge => error.TooLarge,
        // 書く長さは入力から決めるので、食い違うのは kiln の不具合
        else => error.InternalError,
    };
}

/// チャンネルごとに分かれた f32(Web Audio の AudioBuffer と同じ並び)を FLAC にする一括版。
/// どのチャンネルも同じ長さ。ビット深度の既定は 16。返したバイト列は呼び出し側が `gpa` で解放する
pub fn encodePlanarAlloc(gpa: std.mem.Allocator, channels: []const []const f32, sample_rate: u32, options: WriteOptions) WriteError![]u8 {
    if (channels.len == 0 or channels.len > 8) return error.InvalidOptions;
    const frames = channels[0].len;
    for (channels) |c| if (c.len != frames) return error.InvalidOptions;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var enc = Encoder.init(gpa, &out.writer, .{
        .sample_rate = sample_rate,
        .channels = @intCast(channels.len),
        .bits_per_sample = options.bits_per_sample orelse 16,
        .compression = options.compression,
        .total_samples = frames,
        .dither = options.dither,
        .vendor = vendor,
    }) catch |err| return mapWriteError(err);
    defer enc.deinit();
    var buf: [4096]f32 = undefined;
    const nch = channels.len;
    const per = buf.len / nch;
    var i: usize = 0;
    while (i < frames) {
        const n = @min(per, frames - i);
        for (0..n) |j| {
            for (channels, 0..) |c, ch| buf[j * nch + ch] = c[i + j];
        }
        enc.writeF32(buf[0 .. n * nch]) catch |err| return mapWriteError(err);
        i += n;
    }
    return finishAlloc(&enc, &out);
}

test {
    _ = stream;
    _ = encoder;
    _ = @import("flac/lpc.zig");
    _ = decoder;
    _ = @import("flac/bits.zig");
    _ = @import("flac/frame.zig");
    _ = metadata;
}

const testdata = @import("testdata");

test probe {
    const i = try probe(testdata.s16_stereo_flac);
    try std.testing.expectEqual(44100, i.sample_rate);
    try std.testing.expectEqual(2, i.channels);
    try std.testing.expectEqual(16, i.bits_per_sample);
    try std.testing.expectEqual(11025, i.samples);
    try std.testing.expectEqual(10, i.frames);
    try std.testing.expect(!std.mem.allEqual(u8, &i.md5, 0));
    const u = try probe(testdata.u8_mono_flac);
    try std.testing.expectEqual(8, u.bits_per_sample);
    try std.testing.expectEqual(2001, u.samples);
    try std.testing.expectEqual(20, (try probe(testdata.s20_mono_flac)).bits_per_sample);
    try std.testing.expectEqual(3, (try probe(testdata.s32_3ch_flac)).channels);
    try std.testing.expectError(error.NotFlac, probe(testdata.s16_stereo_wav));
    try std.testing.expect(hasSignature(testdata.s16_stereo_flac));
    try std.testing.expect(!hasSignature(testdata.lyria_like));
}

/// テスト用: WAV の data チャンクの中身(末尾にあるもの)
fn wavData(w: []const u8) ![]const u8 {
    const i = try wav.probe(w);
    const len: usize = @intCast(i.samples * i.channels * i.format.bytes());
    const pad = len % 2;
    return w[w.len - pad - len ..][0..len];
}

test "toWavAlloc: ビット深度を保つ形式なら元の WAV と同じ PCM" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ testdata.s16_stereo_flac, testdata.s16_stereo_wav },
        .{ testdata.s24_stereo_flac, testdata.s24_stereo_wav },
        .{ testdata.u8_mono_flac, testdata.u8_mono_wav },
        .{ testdata.s32_3ch_flac, testdata.s32_3ch_ext_wav },
    };
    for (cases) |c| {
        // 元の WAV は、FLAC にした長さ(s32 は 0.05 秒)の先頭だけ比べる
        const t = try toWavAlloc(gpa, c[0], .{}, .{});
        defer gpa.free(t.data);
        const src = try wav.trimAlloc(gpa, c[1], .{ .end = t.result.end });
        defer gpa.free(src.data);
        try std.testing.expectEqualSlices(u8, try wavData(src.data), try wavData(t.data));
        try std.testing.expectEqual(0, t.result.invalid_frames);
    }
    // 20bit は i24 の上位 20 ビットに入る(下位 4 ビットは 0)
    const t = try toWavAlloc(gpa, testdata.s20_mono_flac, .{}, .{});
    defer gpa.free(t.data);
    try std.testing.expectEqual(pcm.Format.i24, (try wav.probe(t.data)).format);
    const d = try wavData(t.data);
    var nonzero = false;
    for (0..d.len / 3) |k| {
        try std.testing.expectEqual(0, d[k * 3] & 0x0F);
        if (d[k * 3] != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
}

test "toWav: 形式を変える(ビット数を減らす、浮動小数点)" {
    const gpa = std.testing.allocator;
    for ([_]pcm.Format{ .u8, .i16, .i24, .i32, .f32, .f64 }) |f| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const r = try toWav(gpa, testdata.s24_stereo_flac, .{ .start = 1000, .end = 9001 }, .{ .format = f }, &out.writer);
        try std.testing.expectEqual(DecodeResult{
            .start = 1000,
            .end = 9001,
            .sample_rate = 48000,
            .channels = 2,
            .bits_per_sample = 24,
            .invalid_frames = 0,
        }, r);
        const i = try wav.probe(out.written());
        try std.testing.expectEqual(f, i.format);
        try std.testing.expectEqual(8001, i.samples);
        const a = try toWavAlloc(gpa, testdata.s24_stereo_flac, .{ .start = 1000, .end = 9001 }, .{ .format = f });
        defer gpa.free(a.data);
        try std.testing.expectEqualSlices(u8, out.written(), a.data);
    }
    try std.testing.expectError(error.EmptyRange, toWavAlloc(gpa, testdata.s16_stereo_flac, .{ .start = 11025 }, .{}));
}

/// テスト用: 受け取ったサンプルをためる
const CollectSink = struct {
    list: std.ArrayList(i32) = .empty,

    pub fn writeI32(c: *CollectSink, samples: []const i32) !void {
        try c.list.appendSlice(std.testing.allocator, samples);
    }

    fn deinit(c: *CollectSink) void {
        c.list.deinit(std.testing.allocator);
    }
};

test "decode: 区間の途中から復号しても、先頭から復号したときと同じ" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ testdata.s16_stereo_flac, testdata.u8_mono_flac, testdata.s32_3ch_flac }) |in| {
        var all: CollectSink = .{};
        defer all.deinit();
        const full = try decode(gpa, in, .{}, &all);
        const nch = full.channels;
        try std.testing.expectEqual(full.end * nch, all.list.items.len);
        for ([_][2]u64{ .{ 1, 2 }, .{ 575, 577 }, .{ 1151, 1153 }, .{ 1152, 2304 }, .{ 1000, 2001 }, .{ 0, full.end } }) |se| {
            const end = @min(se[1], full.end);
            var part: CollectSink = .{};
            defer part.deinit();
            const r = try decode(gpa, in, .{ .start = se[0], .end = se[1] }, &part);
            try std.testing.expectEqual(end, r.end);
            try std.testing.expectEqualSlices(i32, all.list.items[@intCast(se[0] * nch)..@intCast(end * nch)], part.list.items);
        }
    }
}

/// テスト用: s16-stereo.flac の `index` 番目のフレームの範囲
fn frameRange(input: []const u8, index: usize) ![2]usize {
    const s = try stream.Stream.parse(input);
    var it = s.iterator(input);
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == index) return .{ f.start, f.end };
    }
    return error.TestUnexpectedResult;
}

/// テスト用: s16-stereo.flac を壊した `bad` で、フレーム 3 だけが無音になり、ほかは元と同じこと
fn expectFrame3Silenced(bad: []const u8) !void {
    const gpa = std.testing.allocator;
    var all: CollectSink = .{};
    defer all.deinit();
    _ = try decode(gpa, testdata.s16_stereo_flac, .{}, &all);

    const i = try probe(bad);
    try std.testing.expectEqual(11025, i.samples);
    try std.testing.expectEqual(10, i.frames);
    var got: CollectSink = .{};
    defer got.deinit();
    const r = try decode(gpa, bad, .{}, &got);
    try std.testing.expectEqual(1, r.invalid_frames);
    const a = 3 * 1152 * 2;
    const b = 4 * 1152 * 2;
    try std.testing.expectEqual(all.list.items.len, got.list.items.len);
    try std.testing.expectEqualSlices(i32, all.list.items[0..a], got.list.items[0..a]);
    try std.testing.expect(std.mem.allEqual(i32, got.list.items[a..b], 0));
    try std.testing.expectEqualSlices(i32, all.list.items[b..], got.list.items[b..]);
    // 壊れたフレームにかからない区間では数えない
    var part: CollectSink = .{};
    defer part.deinit();
    try std.testing.expectEqual(0, (try decode(gpa, bad, .{ .end = 3 * 1152 }, &part)).invalid_frames);
}

test "壊れたフレームは無音にして数える(中身、ヘッダ、フレームの欠落、偽の同期コード)" {
    const gpa = std.testing.allocator;
    const in = testdata.s16_stereo_flac;
    const fr = try frameRange(in, 3);
    const next = try frameRange(in, 4);

    // 中身の 1 ビット
    const body = try gpa.dupe(u8, in);
    defer gpa.free(body);
    body[(fr[0] + fr[1]) / 2] ^= 0x10;
    try expectFrame3Silenced(body);

    // ヘッダの 1 ビット(CRC-8 が合わなくなる)。後ろのフレームは失われない
    const head = try gpa.dupe(u8, in);
    defer gpa.free(head);
    head[fr[0] + 2] ^= 0x01;
    try expectFrame3Silenced(head);

    // フレームがまるごと欠けている: フレーム番号の飛びから長さを求めて無音にする
    const cut = try std.mem.concat(gpa, u8, &.{ in[0..fr[0]], in[fr[1]..] });
    defer gpa.free(cut);
    try expectFrame3Silenced(cut);

    // 壊れたフレームの中に、次のフレームと同じヘッダ(CRC-8 も番号も正しい)が現れても、そこで区切らない
    const fake = try gpa.dupe(u8, in);
    defer gpa.free(fake);
    // s16-stereo.flac のフレームヘッダは 6 バイト。サブフレームの先頭まで少し余分に写す
    const hlen = 8;
    @memcpy(fake[(fr[0] + fr[1]) / 2 ..][0..hlen], in[next[0]..][0..hlen]);
    try expectFrame3Silenced(fake);
}

test "最後のフレームが途中で切れていたら数えない。後ろのタグや前の ID3v2 タグは読み飛ばす" {
    const gpa = std.testing.allocator;
    const in = testdata.s16_stereo_flac;
    const last = try frameRange(in, 9);
    try std.testing.expectEqual(in.len, last[1]);
    const cut = try probe(in[0 .. last[1] - 10]);
    try std.testing.expectEqual(9 * 1152, cut.samples);

    // 末尾の ID3v1 タグ
    const tagged = try std.mem.concat(gpa, u8, &.{ in, "TAG" ++ @as([125]u8, @splat(' ')) });
    defer gpa.free(tagged);
    try std.testing.expectEqual(11025, (try probe(tagged)).samples);
    // 先頭の ID3v2 タグ
    const id3 = try std.mem.concat(gpa, u8, &.{ "ID3\x03\x00\x00\x00\x00\x00\x04abcd", in });
    defer gpa.free(id3);
    const a = try toWavAlloc(gpa, in, .{}, .{});
    defer gpa.free(a.data);
    const b = try toWavAlloc(gpa, id3, .{}, .{});
    defer gpa.free(b.data);
    try std.testing.expectEqualSlices(u8, a.data, b.data);
}

/// テスト用: 可変長の番号(UTF-8 に似た符号)を書く
fn putCodedNumber(list: *std.ArrayList(u8), v: u64) !void {
    const gpa = std.testing.allocator;
    // バイト数ごとに書けるビット数(1 バイトなら 7、2 バイトなら 5 + 6 …)
    const caps = [_]u6{ 7, 11, 16, 21, 26, 31, 36 };
    var len: usize = 1;
    while (v >> caps[len - 1] != 0) len += 1;
    if (len == 1) return list.append(gpa, @intCast(v));
    const cont: u6 = @intCast(len - 1);
    // 先頭のバイト: len 個の 1 と 0 に続けて、上位のビット
    const lead: u8 = @truncate(@as(u16, 0xFF00) >> @intCast(len));
    try list.append(gpa, lead | @as(u8, @intCast(v >> (6 * cont))));
    var k = cont;
    while (k > 0) {
        k -= 1;
        try list.append(gpa, 0x80 | @as(u8, @intCast((v >> (6 * k)) & 0x3F)));
    }
}

/// テスト用: s16-stereo.flac の各フレームの番号を `numbers[i]` に書き換え、CRC-8 と CRC-16 を付け直す。
/// `keep` 個目より後のフレームは捨てる。`total` があれば STREAMINFO の総サンプル数も書き換える
fn renumbered(numbers: []const u64, keep: usize, total: ?u64) ![]u8 {
    const gpa = std.testing.allocator;
    const frame = @import("flac/frame.zig");
    const in = testdata.s16_stereo_flac;
    const s = try stream.Stream.parse(in);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, in[0..s.meta.frames_start]);
    if (total) |t| {
        // STREAMINFO は fLaC(4)とブロックのヘッダ(4)の後。総サンプル数は 13 バイト目からの 36 ビット
        const si = out.items[8..][0..34];
        const v = std.mem.readInt(u64, si[10..18], .big);
        std.mem.writeInt(u64, si[10..18], (v & ~@as(u64, (1 << 36) - 1)) | t, .big);
    }
    var it = s.iterator(in);
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == keep) break;
        const h = f.header.?;
        const fr = f.bytes(in);
        const begin = out.items.len;
        try out.appendSlice(gpa, fr[0..4]);
        try putCodedNumber(&out, numbers[i]);
        // 番号の後のブロック長・サンプルレート(あれば)はそのまま写す
        const old_len: usize = if (fr[4] < 0x80) 1 else @clz(~fr[4]);
        try out.appendSlice(gpa, fr[4 + old_len .. h.len - 1]);
        try out.append(gpa, frame.Crc8.hash(out.items[begin..]));
        try out.appendSlice(gpa, fr[h.len .. fr.len - 2]);
        var crc: [2]u8 = undefined;
        std.mem.writeInt(u16, &crc, frame.Crc16.hash(out.items[begin..]), .big);
        try out.appendSlice(gpa, &crc);
    }
    return out.toOwnedSlice(gpa);
}

test "番号が大きく飛んだフレームでは区切り直さない(失われた長さに上限)" {
    const gpa = std.testing.allocator;
    // フレーム 0 の次が番号 10 億のフレーム(CRC は正しい)
    for ([_]?u64{ null, 0 }) |total| {
        const in = try renumbered(&.{ 0, 1_000_000_000 }, 2, total);
        defer gpa.free(in);
        const i = try probe(in);
        try std.testing.expectEqual(1152, i.samples);
        try std.testing.expectEqual(1, i.frames);
    }
    // 小さな飛び(フレーム 1 が失われた)なら無音で埋める
    const ok = try renumbered(&.{ 0, 2, 3 }, 3, null);
    defer gpa.free(ok);
    try std.testing.expectEqual(4 * 1152, (try probe(ok)).samples);
}

test "番号がサンプル位置の古い形式: ヘッダが壊れても長さは変わらない" {
    const gpa = std.testing.allocator;
    var nums: [10]u64 = undefined;
    for (&nums, 0..) |*n, k| n.* = k * 1152;
    const base = try renumbered(&nums, 10, null);
    defer gpa.free(base);
    try std.testing.expectEqual(11025, (try probe(base)).samples);
    // 番号を書き換えても PCM は元と同じ
    var all: CollectSink = .{};
    defer all.deinit();
    _ = try decode(gpa, base, .{}, &all);
    var orig: CollectSink = .{};
    defer orig.deinit();
    _ = try decode(gpa, testdata.s16_stereo_flac, .{}, &orig);
    try std.testing.expectEqualSlices(i32, orig.list.items, all.list.items);
    // 最初のフレーム、2 つ目のフレーム(番号の付け方を決める前)、途中のフレームのヘッダを壊す
    for ([_]usize{ 0, 1, 3 }) |k| {
        const bad = try gpa.dupe(u8, base);
        defer gpa.free(bad);
        const s = try stream.Stream.parse(base);
        var it = s.iterator(base);
        var j: usize = 0;
        while (it.next()) |f| : (j += 1) {
            if (j == k) {
                bad[f.start + 2] ^= 0x01;
                break;
            }
        }
        const i = try probe(bad);
        try std.testing.expectEqual(11025, i.samples);
        try std.testing.expectEqual(10, i.frames);
        var got: CollectSink = .{};
        defer got.deinit();
        try std.testing.expectEqual(1, (try decode(gpa, bad, .{}, &got)).invalid_frames);
    }
}

test "encode: WAV → FLAC → 復号で元の PCM に戻る(すべての段階)" {
    const gpa = std.testing.allocator;
    const wav_files = [_][]const u8{ testdata.s16_stereo_wav, testdata.u8_mono_wav, testdata.s24_stereo_wav, testdata.s32_3ch_ext_wav };
    for (wav_files) |w| {
        for (0..max_compression + 1) |level| {
            const f = try wav.toFlacAlloc(gpa, w, .{}, .{ .compression = @intCast(level) });
            defer gpa.free(f.data);
            const back = try toWavAlloc(gpa, f.data, .{}, .{});
            defer gpa.free(back.data);
            try std.testing.expectEqual(0, back.result.invalid_frames);
            const src = try wav.trimAlloc(gpa, w, .{});
            defer gpa.free(src.data);
            try std.testing.expectEqualSlices(u8, try wavData(src.data), try wavData(back.data));
            // STREAMINFO の総サンプル数と MD5
            const i = try probe(f.data);
            try std.testing.expectEqual((try wav.probe(w)).samples, i.samples);
            try std.testing.expect(!std.mem.allEqual(u8, &i.md5, 0));
        }
    }
}

test "encode: 端のケース(長さ、無音、満幅の値、ビット深度、サンプルレート、チャンネル数)を往復できる" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6B696C6E);
    const rand = prng.random();
    const Signal = enum { noise, silence, extremes, ramp };
    for ([_]u8{ 4, 8, 12, 15, 16, 20, 24, 32 }) |b| {
        for ([_]u8{ 1, 2, 3 }) |nch| {
            for ([_]usize{ 1, 2, 15, 1152, 5000 }) |frames| {
                for ([_]u8{ 0, 5, 8 }) |level| {
                    for (std.enums.values(Signal)) |sig| {
                        const lim: i64 = @as(i64, 1) << @intCast(b - 1);
                        const samples = try gpa.alloc(i32, frames * nch);
                        defer gpa.free(samples);
                        for (samples, 0..) |*v, i| v.* = @intCast(switch (sig) {
                            .noise => rand.intRangeLessThan(i64, -lim, lim),
                            .silence => 0,
                            // 満幅の正負を交互に(side が 1 ビット多くなる)
                            .extremes => if ((i / nch + i % nch) % 2 == 0) lim - 1 else -lim,
                            .ramp => @mod(@as(i64, @intCast(i * 37)), 2 * lim) - lim,
                        });
                        // 珍しいサンプルレート(ヘッダに書けないもの)も混ぜる
                        const rate: u32 = if (frames == 15) 768000 else if (frames == 2) 39000 else 44100;
                        var out: Io.Writer.Allocating = .init(gpa);
                        defer out.deinit();
                        var enc: Encoder = try .init(gpa, &out.writer, .{
                            .sample_rate = rate,
                            .channels = nch,
                            .bits_per_sample = b,
                            .compression = level,
                            .total_samples = frames,
                        });
                        defer enc.deinit();
                        try enc.writeI32(samples);
                        const data = try finishAlloc(&enc, &out);
                        defer gpa.free(data);

                        var got: CollectSink = .{};
                        defer got.deinit();
                        const r = try decode(gpa, data, .{}, &got);
                        try std.testing.expectEqual(0, r.invalid_frames);
                        try std.testing.expectEqual(rate, r.sample_rate);
                        try std.testing.expectEqualSlices(i32, samples, got.list.items);
                    }
                }
            }
        }
    }
}

test "encode: MD5 は復号した PCM の MD5" {
    const gpa = std.testing.allocator;
    const f = try wav.toFlacAlloc(gpa, testdata.u8_mono_wav, .{}, .{});
    defer gpa.free(f.data);
    var got: CollectSink = .{};
    defer got.deinit();
    _ = try decode(gpa, f.data, .{}, &got);
    // 8bit は 1 バイトの符号付き
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (got.list.items) |v| md5.update(&.{@as(u8, @bitCast(@as(i8, @intCast(v))))});
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    try std.testing.expectEqualSlices(u8, &digest, &(try probe(f.data)).md5);
}

test "encode: 指定の誤り、長さの食い違い" {
    const gpa = std.testing.allocator;
    var discard: Io.Writer.Discarding = .init(&.{});
    for ([_]EncoderOptions{
        .{ .sample_rate = 44100, .channels = 0, .bits_per_sample = 16 },
        .{ .sample_rate = 44100, .channels = 9, .bits_per_sample = 16 },
        .{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 3 },
        .{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 33 },
        .{ .sample_rate = 0, .channels = 2, .bits_per_sample = 16 },
        .{ .sample_rate = 1 << 20, .channels = 2, .bits_per_sample = 16 },
        .{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 16, .compression = 9 },
    }) |o| try std.testing.expectError(error.InvalidOptions, Encoder.init(gpa, &discard.writer, o));
    var enc: Encoder = try .init(gpa, &discard.writer, .{ .sample_rate = 44100, .channels = 1, .bits_per_sample = 16, .total_samples = 3 });
    defer enc.deinit();
    try enc.writeI32(&.{ 1, 2 });
    try std.testing.expectError(error.LengthMismatch, enc.finish());
    const l = [_]f32{ 0, 0.5 };
    try std.testing.expectError(error.InvalidOptions, encodePlanarAlloc(gpa, &.{ &l, l[0..1] }, 44100, .{}));
    try std.testing.expectError(error.InvalidOptions, encodePlanarAlloc(gpa, &.{}, 44100, .{}));
}

test "mp3.toFlacAlloc / encodePlanarAlloc" {
    const gpa = std.testing.allocator;
    const m = try mp3.toFlacAlloc(gpa, testdata.lyria_like, .{ .start = 100, .end = 5000 }, .{});
    defer gpa.free(m.data);
    const i = try probe(m.data);
    try std.testing.expectEqual(4900, i.samples);
    try std.testing.expectEqual(16, i.bits_per_sample);
    try std.testing.expectEqual(0, m.result.invalid_frames);
    // MP3 → WAV(16bit、同じディザ)と同じ PCM
    const w = try mp3.toWavAlloc(gpa, testdata.lyria_like, .{ .start = 100, .end = 5000 }, .{});
    defer gpa.free(w.data);
    const back = try toWavAlloc(gpa, m.data, .{}, .{});
    defer gpa.free(back.data);
    try std.testing.expectEqualSlices(u8, try wavData(w.data), try wavData(back.data));

    const l = [_]f32{ 0, 0.5, -0.5, 1 };
    const data = try encodePlanarAlloc(gpa, &.{&l}, 8000, .{ .bits_per_sample = 8, .dither = .none });
    defer gpa.free(data);
    var got: CollectSink = .{};
    defer got.deinit();
    _ = try decode(gpa, data, .{}, &got);
    try std.testing.expectEqualSlices(i32, &.{ 0, 64, -64, 127 }, got.list.items);
}

/// テスト用: インターリーブした整数を FLAC にする
fn encodeInts(samples: []const i32, nch: u8, bits: u8, level: u8) ![]u8 {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var enc: Encoder = try .init(gpa, &out.writer, .{
        .sample_rate = 44100,
        .channels = nch,
        .bits_per_sample = bits,
        .compression = level,
        .total_samples = samples.len / nch,
    });
    defer enc.deinit();
    try enc.writeI32(samples);
    return finishAlloc(&enc, &out);
}

test "encode: 32bit の満幅の矩形波(固定予測の残差が 32 ビットを超える)も正しく書ける" {
    const gpa = std.testing.allocator;
    for ([_]u8{ 1, 2 }) |nch| {
        const samples = try gpa.alloc(i32, 8192 * @as(usize, nch));
        defer gpa.free(samples);
        for (samples, 0..) |*v, i| v.* = if ((i / nch / 2048) % 2 == 0) std.math.maxInt(i32) else std.math.minInt(i32);
        for ([_]u8{ 0, 5, 8 }) |level| {
            const data = try encodeInts(samples, nch, 32, level);
            defer gpa.free(data);
            var got: CollectSink = .{};
            defer got.deinit();
            try std.testing.expectEqual(0, (try decode(gpa, data, .{}, &got)).invalid_frames);
            try std.testing.expectEqualSlices(i32, samples, got.list.items);
        }
    }
}
