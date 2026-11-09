// SPDX-License-Identifier: MIT
//! WAV(RIFF / WAVE、PCM と浮動小数点)の解析と、サンプル精度のトリム。
//!
//! 位置はフレーム(チャンネルあたりのサンプル)単位で、先頭を 0 とする。
//! トリムは `data` の中身を切り出すだけなので、元の形式のまま無劣化になる。
const std = @import("std");
const Io = std.Io;
const pcm = @import("pcm.zig");
const parse = @import("wav/parse.zig");
const header = @import("wav/header.zig");
const encoder = @import("wav/encoder.zig");

pub const ParseError = parse.Error;

/// ストリーミングのエンコーダ(`init → writeF32 / writePlanarF32 / writeRaw → finish`)
pub const Encoder = encoder.Encoder;
pub const EncoderOptions = encoder.Options;
pub const EncodeOptions = encoder.EncodeOptions;
pub const EncodeError = encoder.Error;
pub const Header = encoder.Header;
/// エンコーダが書くヘッダの最大のバイト数
pub const max_header_len = encoder.max_header_len;

/// チャンネルごとに分かれた f32 のサンプル(Web Audio の AudioBuffer と同じ並び)を WAV にする一括版。
/// どのチャンネルも同じ長さ。返したバイト列は呼び出し側が `gpa` で解放する
pub fn encodePlanarAlloc(
    gpa: std.mem.Allocator,
    channels: []const []const f32,
    options: EncodeOptions,
) (error{ OutOfMemory, InvalidOptions, TooLarge, InternalError })![]u8 {
    if (channels.len == 0 or channels.len > std.math.maxInt(u16)) return error.InvalidOptions;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var e = encodeInit(&out.writer, channels, options) catch |err| return mapWriteFailed(err);
    e.writePlanarF32(channels) catch |err| return mapWriteFailed(err);
    _ = e.finish() catch |err| return mapWriteFailed(err);
    return out.toOwnedSlice();
}

fn encodeInit(w: *Io.Writer, channels: []const []const f32, options: EncodeOptions) EncodeError!Encoder {
    return .init(w, .{
        .sample_rate = options.sample_rate,
        .channels = @intCast(channels.len),
        .format = options.format,
        .dither = options.dither,
        .frames = channels[0].len,
    });
}

fn mapWriteFailed(err: EncodeError) error{ OutOfMemory, InvalidOptions, TooLarge, InternalError } {
    return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.InvalidOptions => error.InvalidOptions,
        error.TooLarge => error.TooLarge,
        // フレーム数は入力の長さから決めるので、食い違うのは kiln の不具合。止めずにエラーとして返す
        error.LengthMismatch => error.InternalError,
    };
}

pub const Info = struct {
    sample_rate: u32,
    channels: u16,
    format: pcm.Format,
    /// フレーム数(チャンネルあたりのサンプル数)
    samples: u64,
};

/// 入力全体を解析して、サンプルレートや長さを返す
pub fn probe(input: []const u8) ParseError!Info {
    const w = try parse.Wav.parse(input);
    return .{ .sample_rate = w.sample_rate, .channels = w.channels, .format = w.format, .samples = w.frames() };
}

pub const TrimOptions = struct {
    /// 切り出す区間の先頭(フレーム)
    start: u64 = 0,
    /// 切り出す区間の終わり(この位置は含まない)。null なら末尾まで
    end: ?u64 = null,
};

/// 実際に切り出した区間(範囲外の指定を丸めた後の位置)
pub const TrimResult = struct {
    start: u64,
    end: u64,
    sample_rate: u32,
};

pub const TrimError = ParseError || Io.Writer.Error || error{
    /// 丸めた後の区間が空(start >= end)
    EmptyRange,
    /// 出力が RIFF の 32bit のサイズに収まらない(4GiB 以上)
    TooLarge,
};

/// 区間 `[options.start, options.end)` を切り出し、`w` に WAV で書く。末尾は入力の長さで切り詰める。
/// `fmt ` チャンクは入力のものをそのまま使い、ほかのチャンク(`LIST` など)は引き継がない。
/// `w.flush()` は呼び出し側が行う
pub fn trim(input: []const u8, options: TrimOptions, w: *Io.Writer) TrimError!TrimResult {
    const wav = try parse.Wav.parse(input);
    const frames = wav.frames();
    const end = @min(options.end orelse frames, frames);
    if (options.start >= end) return error.EmptyRange;

    const frame_len = wav.frameLen();
    const data = wav.data[@intCast(options.start * frame_len)..@intCast(end * frame_len)];
    if (header.riffSize(wav.fmt_chunk, data.len) == null) return error.TooLarge;
    try header.write(w, wav.fmt_chunk, @intCast(data.len));
    try w.writeAll(data);
    if (data.len % 2 == 1) try w.writeByte(0);
    return .{ .start = options.start, .end = end, .sample_rate = wav.sample_rate };
}

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

test {
    _ = parse;
    _ = header;
    _ = encoder;
}

test encodePlanarAlloc {
    const l = [_]f32{ 0, 0.5, -0.5, 1 };
    const r = [_]f32{ 0.25, -0.25, 0, -1 };
    const data = try encodePlanarAlloc(std.testing.allocator, &.{ &l, &r }, .{ .sample_rate = 44100, .dither = .none });
    defer std.testing.allocator.free(data);
    const i = try probe(data);
    try std.testing.expectEqual(Info{ .sample_rate = 44100, .channels = 2, .format = .i16, .samples = 4 }, i);
    try std.testing.expectError(error.InvalidOptions, encodePlanarAlloc(std.testing.allocator, &.{}, .{ .sample_rate = 44100 }));
}

const testdata = @import("testdata");

test "trim: 切り出した PCM が入力のバイト列そのまま" {
    const T = struct { []const u8, u64, ?u64 };
    for ([_]T{
        .{ testdata.s16_stereo_wav, 1000, 5000 },
        .{ testdata.u8_mono_wav, 1, 2000 }, // 奇数バイトの data(詰め物が要る)
        .{ testdata.u8_mono_wav, 0, null },
        .{ testdata.s24_stereo_wav, 12345 % 12000, null },
        .{ testdata.f32_stereo_wav, 0, 1 },
        .{ testdata.f64_mono_wav, 100, 5000 },
        .{ testdata.s32_3ch_ext_wav, 7, 11999 },
    }) |c| {
        const in = try parse.Wav.parse(c[0]);
        const t = try trimAlloc(std.testing.allocator, c[0], .{ .start = c[1], .end = c[2] });
        defer std.testing.allocator.free(t.data);
        const out = try parse.Wav.parse(t.data);
        const end = c[2] orelse in.frames();
        try std.testing.expectEqual(c[1], t.start);
        try std.testing.expectEqual(end, t.end);
        try std.testing.expectEqual(end - c[1], out.frames());
        try std.testing.expectEqualSlices(u8, in.fmt_chunk, out.fmt_chunk);
        try std.testing.expectEqualSlices(u8, in.data[@intCast(c[1] * in.frameLen())..@intCast(end * in.frameLen())], out.data);
        // RIFF のサイズが出力全体と合う(詰め物を含む)
        try std.testing.expectEqual(t.data.len - 8, std.mem.readInt(u32, t.data[4..8], .little));
    }
}

test "trim: 範囲外は丸める" {
    const r = try trimAlloc(std.testing.allocator, testdata.s16_stereo_wav, .{ .start = 11000, .end = 1 << 40 });
    defer std.testing.allocator.free(r.data);
    try std.testing.expectEqual(11025, r.end);
    var discard: Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.EmptyRange, trim(testdata.s16_stereo_wav, .{ .start = 11025 }, &discard.writer));
    try std.testing.expectError(error.EmptyRange, trim(testdata.s16_stereo_wav, .{ .start = 10, .end = 10 }, &discard.writer));
    try std.testing.expectError(error.NotWav, trim(testdata.lyria_like, .{}, &discard.writer));
}

test probe {
    const i = try probe(testdata.s24_stereo_wav);
    try std.testing.expectEqual(Info{ .sample_rate = 48000, .channels = 2, .format = .i24, .samples = 12000 }, i);
}
