// SPDX-License-Identifier: MIT
//! WAV のエンコーダ。`init → write を何度でも → finish` の形で、`*std.Io.Writer` にストリーミングで書く。
//!
//! 書くフレーム数を最初に渡せば、正しい長さのヘッダを先に書く。渡さなければ長さを 0xFFFFFFFF にした
//! ヘッダを書いておき、`finish` が正しいヘッダのバイト列を返すので、呼び出し側が先頭に書き戻す
//! (`std.Io.Writer` はシークできないため。docs/architecture.md §2)。
const std = @import("std");
const Io = std.Io;
const pcm = @import("../pcm.zig");
const header = @import("header.zig");

/// 書き出しの設定のうち、入力の形によらないもの
pub const EncodeOptions = struct {
    sample_rate: u32,
    /// 書き出すサンプル形式
    format: pcm.Format = .i16,
    /// 浮動小数点を整数形式で書くときのディザ
    dither: pcm.Dither = .tpdf,
};

pub const Options = struct {
    sample_rate: u32,
    channels: u16,
    format: pcm.Format = .i16,
    dither: pcm.Dither = .tpdf,
    /// 書くフレーム数。分かっていれば渡すと、先に正しいヘッダを書ける
    frames: ?u64 = null,
};

pub const Error = Io.Writer.Error || error{
    /// サンプルレートかチャンネル数が 0、1 フレームのバイト数が 65535 を超える、
    /// またはサンプルレート × 1 フレームのバイト数が 32bit に収まらない(WAV のヘッダに書けない)
    InvalidOptions,
    /// 出力が RIFF の 32bit のサイズに収まらない(4GiB 以上)
    TooLarge,
    /// `frames` で渡したフレーム数と、実際に書いたフレーム数が違う
    LengthMismatch,
};

/// `Encoder.init` が返しうるエラー(`LengthMismatch` は `finish` だけが返す)
pub const InitError = Io.Writer.Error || error{ InvalidOptions, TooLarge };
/// `writeF32` などの書き込みが返しうるエラー
pub const WriteError = Io.Writer.Error || error{TooLarge};

/// `fmt ` チャンクの最大長(WAVE_FORMAT_EXTENSIBLE)
const max_fmt_len = 40;
/// ヘッダの最大長
pub const max_header_len = header.len(&@as([max_fmt_len]u8, @splat(0)));

/// 先頭に書き戻すヘッダのバイト列
pub const Header = struct {
    buf: [max_header_len]u8,
    len: usize,

    pub fn bytes(h: *const Header) []const u8 {
        return h.buf[0..h.len];
    }
};

pub const Encoder = struct {
    w: *Io.Writer,
    channels: u16,
    format: pcm.Format,
    quantizer: pcm.Quantizer,
    fmt_buf: [max_fmt_len]u8,
    fmt_len: u8,
    expected_frames: ?u64,
    /// 書いた PCM のバイト数
    written: u64 = 0,

    /// ヘッダを書いてエンコーダを作る
    pub fn init(w: *Io.Writer, options: Options) InitError!Encoder {
        try validate(options);
        var e: Encoder = .{
            .w = w,
            .channels = options.channels,
            .format = options.format,
            .quantizer = .init(options.dither),
            .fmt_buf = undefined,
            .fmt_len = 0,
            .expected_frames = options.frames,
        };
        e.fmt_len = @intCast(buildFmt(&e.fmt_buf, options.sample_rate, options.channels, options.format).len);
        if (options.frames) |n| {
            const data_len = std.math.mul(u64, n, e.frameLen()) catch return error.TooLarge;
            if (header.riffSize(e.fmtChunk(), data_len) == null) return error.TooLarge;
            try header.write(w, e.fmtChunk(), @intCast(data_len));
        } else {
            try header.writeSizes(w, e.fmtChunk(), 0xFFFF_FFFF, 0xFFFF_FFFF);
        }
        return e;
    }

    /// フレーム数 `options.frames` の WAV を書いたときの、ファイル全体のバイト数(ヘッダと、
    /// 奇数バイトの詰め物を含む)。`init` と同じ指定の誤りと、4GiB を超える(`TooLarge`)ときはエラー
    pub fn fileLen(options: Options) error{ InvalidOptions, TooLarge }!u64 {
        try validate(options);
        var buf: [max_fmt_len]u8 = undefined;
        const fmt_chunk = buildFmt(&buf, options.sample_rate, options.channels, options.format);
        const frame_len = @as(u64, options.channels) * options.format.bytes();
        const data_len = std.math.mul(u64, options.frames orelse 0, frame_len) catch return error.TooLarge;
        const riff = header.riffSize(fmt_chunk, data_len) orelse return error.TooLarge;
        return @as(u64, riff) + 8;
    }

    /// `fmt ` の nBlockAlign(16bit)と nAvgBytesPerSec(32bit)に収まる指定か
    fn validate(options: Options) error{InvalidOptions}!void {
        if (options.sample_rate == 0 or options.channels == 0) return error.InvalidOptions;
        const block = @as(u32, options.channels) * options.format.bytes();
        if (block > std.math.maxInt(u16)) return error.InvalidOptions;
        _ = std.math.mul(u32, options.sample_rate, block) catch return error.InvalidOptions;
    }

    fn fmtChunk(e: *const Encoder) []const u8 {
        return e.fmt_buf[0..e.fmt_len];
    }

    /// 1 フレームのバイト数
    pub fn frameLen(e: *const Encoder) usize {
        return @as(usize, e.channels) * e.format.bytes();
    }

    /// インターリーブした f32 のサンプルを書く。長さはチャンネル数の倍数
    pub fn writeF32(e: *Encoder, samples: []const f32) WriteError!void {
        std.debug.assert(samples.len % e.channels == 0);
        try e.writeSamples(samples);
    }

    /// チャンネルごとに分かれた f32 のサンプル(Web Audio の AudioBuffer と同じ並び)を書く。
    /// `channels.len` はチャンネル数で、どのチャンネルも同じ長さ
    pub fn writePlanarF32(e: *Encoder, channels: []const []const f32) WriteError!void {
        std.debug.assert(channels.len == e.channels);
        const frames = channels[0].len;
        for (channels) |c| std.debug.assert(c.len == frames);
        // インターリーブしながら f32 のバッファに詰め、いっぱいになったら書く(チャンネル数によらず進む)
        var buf: [1024]f32 = undefined;
        var n: usize = 0;
        for (0..frames) |i| {
            for (channels) |c| {
                buf[n] = c[i];
                n += 1;
                if (n == buf.len) {
                    try e.writeSamples(buf[0..n]);
                    n = 0;
                }
            }
        }
        try e.writeSamples(buf[0..n]);
    }

    /// インターリーブした f32 のサンプルを書く(フレームの途中で区切ってよい)
    fn writeSamples(e: *Encoder, samples: []const f32) WriteError!void {
        var buf: [4096]u8 = undefined;
        const per = buf.len / e.format.bytes();
        var i: usize = 0;
        while (i < samples.len) {
            const n = @min(per, samples.len - i);
            const out = buf[0 .. n * e.format.bytes()];
            pcm.fromF32(e.format, samples[i..][0..n], out, &e.quantizer);
            try e.writeBytes(out);
            i += n;
        }
    }

    /// 書き出す形式のバイト列をそのまま書く。長さはフレームの倍数
    pub fn writeRaw(e: *Encoder, bytes: []const u8) WriteError!void {
        std.debug.assert(bytes.len % e.frameLen() == 0);
        try e.writeBytes(bytes);
    }

    fn writeBytes(e: *Encoder, bytes: []const u8) WriteError!void {
        const total = e.written + bytes.len;
        if (header.riffSize(e.fmtChunk(), total) == null) return error.TooLarge;
        try e.w.writeAll(bytes);
        e.written = total;
    }

    /// 書き終える。`frames` を渡していれば、中身が奇数バイトのとき詰め物を書いて null を返す。
    /// 渡していなければ、先頭に書き戻す正しいヘッダを返す。このときは詰め物を書かない
    /// (書き戻せないパイプなどで、長さ 0xFFFFFFFF のまま読まれると、詰め物がサンプルとして読まれるため)。
    /// `w.flush()` は呼び出し側が行う
    pub fn finish(e: *Encoder) Error!?Header {
        if (e.expected_frames) |n| {
            if (n * e.frameLen() != e.written) return error.LengthMismatch;
            if (e.written % 2 == 1) try e.w.writeByte(0);
            return null;
        }
        var h: Header = .{ .buf = undefined, .len = header.len(e.fmtChunk()) };
        var hw: Io.Writer = .fixed(&h.buf);
        // 詰め物を書いていないので、RIFF のサイズにも含めない
        const riff_size = header.riffSize(e.fmtChunk(), e.written).? - @as(u32, @intCast(e.written % 2));
        header.writeSizes(&hw, e.fmtChunk(), riff_size, @intCast(e.written)) catch unreachable;
        std.debug.assert(hw.end == h.len);
        return h;
    }
};

/// `fmt ` チャンクの中身を作る。2 チャンネル以下は WAVE_FORMAT_PCM / IEEE_FLOAT、
/// 3 チャンネル以上は WAVE_FORMAT_EXTENSIBLE(チャンネルマスクは先頭から順に割り当てる)
fn buildFmt(buf: *[max_fmt_len]u8, sample_rate: u32, channels: u16, format: pcm.Format) []const u8 {
    const block: u16 = @intCast(@as(u32, channels) * format.bytes());
    const tag: u16 = if (format.isFloat()) 3 else 1;
    var w: Io.Writer = .fixed(buf);
    const extensible = channels > 2;
    w.writeInt(u16, if (extensible) 0xFFFE else tag, .little) catch unreachable;
    w.writeInt(u16, channels, .little) catch unreachable;
    w.writeInt(u32, sample_rate, .little) catch unreachable;
    w.writeInt(u32, sample_rate * block, .little) catch unreachable; // init で収まることを確かめてある
    w.writeInt(u16, block, .little) catch unreachable;
    w.writeInt(u16, format.bits(), .little) catch unreachable;
    if (extensible) {
        w.writeInt(u16, 22, .little) catch unreachable; // cbSize
        w.writeInt(u16, format.bits(), .little) catch unreachable; // wValidBitsPerSample
        const mask: u32 = if (channels <= 18) (@as(u32, 1) << @intCast(channels)) - 1 else 0;
        w.writeInt(u32, mask, .little) catch unreachable;
        w.writeInt(u16, tag, .little) catch unreachable;
        w.writeAll("\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71") catch unreachable;
    } else if (format.isFloat()) {
        w.writeInt(u16, 0, .little) catch unreachable; // cbSize
    }
    return w.buffered();
}

const parse = @import("parse.zig");

test "Encoder: f32 から 16bit(ディザなし)と f32 で書き、読み直す" {
    const gpa = std.testing.allocator;
    var src: [2 * 1001]f32 = undefined;
    for (&src, 0..) |*s, i| s.* = @floatCast(0.5 * @sin(@as(f64, @floatFromInt(i)) * 0.05));

    inline for (.{ pcm.Format.i16, pcm.Format.f32, pcm.Format.i24 }) |f| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var e: Encoder = try .init(&out.writer, .{ .sample_rate = 44100, .channels = 2, .format = f, .dither = .none, .frames = 1001 });
        try e.writeF32(src[0..1000]);
        try e.writeF32(src[1000..]);
        try std.testing.expectEqual(null, try e.finish());

        const w = try parse.Wav.parse(out.written());
        try std.testing.expectEqual(44100, w.sample_rate);
        try std.testing.expectEqual(f, w.format);
        try std.testing.expectEqual(1001, w.frames());
        var back: [src.len]f32 = undefined;
        pcm.toF32(f, w.data, &back);
        for (src, back) |a, b| try std.testing.expect(@abs(a - b) <= 0.5 / 32768.0 + 1e-9);
    }
}

test "Encoder: チャンネルごとの入力は、インターリーブした入力と同じ出力になる" {
    const gpa = std.testing.allocator;
    const n = 3000;
    var l: [n]f32 = undefined;
    var r: [n]f32 = undefined;
    var c: [n]f32 = undefined;
    var inter: [n * 3]f32 = undefined;
    for (0..n) |i| {
        const t: f64 = @floatFromInt(i);
        l[i] = @floatCast(@sin(t * 0.01) * 0.3);
        r[i] = @floatCast(@sin(t * 0.02) * 0.3);
        c[i] = @floatCast(@sin(t * 0.03) * 0.3);
        inter[i * 3 ..][0..3].* = .{ l[i], r[i], c[i] };
    }
    var a: Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    var ea: Encoder = try .init(&a.writer, .{ .sample_rate = 48000, .channels = 3, .frames = n });
    try ea.writePlanarF32(&.{ &l, &r, &c });
    _ = try ea.finish();
    var eb: Encoder = try .init(&b.writer, .{ .sample_rate = 48000, .channels = 3, .frames = n });
    try eb.writeF32(&inter);
    _ = try eb.finish();
    try std.testing.expectEqualSlices(u8, a.written(), b.written());
    // 3 チャンネルは WAVE_FORMAT_EXTENSIBLE
    const w = try parse.Wav.parse(a.written());
    try std.testing.expectEqual(40, w.fmt_chunk.len);
    try std.testing.expectEqual(0xFFFE, std.mem.readInt(u16, w.fmt_chunk[0..2], .little));
}

test "Encoder: バッファより多いチャンネル数でも書ける" {
    const gpa = std.testing.allocator;
    const nch = 2000;
    const frames = 3;
    const data = try gpa.alloc(f32, nch * frames);
    defer gpa.free(data);
    const chans = try gpa.alloc([]const f32, nch);
    defer gpa.free(chans);
    for (chans, 0..) |*c, i| {
        c.* = data[i * frames ..][0..frames];
        for (data[i * frames ..][0..frames], 0..) |*v, j| v.* = @as(f32, @floatFromInt(i * frames + j)) / 8192.0;
    }
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var e: Encoder = try .init(&out.writer, .{ .sample_rate = 8000, .channels = nch, .format = .f32, .frames = frames });
    try e.writePlanarF32(chans);
    _ = try e.finish();
    const w = try parse.Wav.parse(out.written());
    try std.testing.expectEqual(frames, w.frames());
    // インターリーブされている: フレーム 1 のチャンネル 1999
    var v: [1]f32 = undefined;
    pcm.toF32(.f32, w.data[(1 * nch + 1999) * 4 ..][0..4], &v);
    try std.testing.expectEqual(chans[1999][1], v[0]);
}

test "Encoder: 長さを渡さなければ、finish が返すヘッダを書き戻す" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var e: Encoder = try .init(&out.writer, .{ .sample_rate = 8000, .channels = 1, .format = .u8, .dither = .none });
    try e.writeRaw(&[_]u8{ 128, 129, 130 });
    const h = (try e.finish()).?;
    // 書き戻す前でも(長さ 0xFFFFFFFF のまま)読める
    try std.testing.expectEqual(3, (try parse.Wav.parse(out.written())).frames());
    const data = out.written();
    @memcpy(data[0..h.len], h.bytes());
    // 詰め物は書かず、RIFF のサイズは出力全体と合う
    try std.testing.expectEqual(data.len - 8, std.mem.readInt(u32, data[4..8], .little));
    const w = try parse.Wav.parse(data);
    try std.testing.expectEqualSlices(u8, &.{ 128, 129, 130 }, w.data);
    try std.testing.expectEqual(130, data[data.len - 1]);
}

test "Encoder: 長さを渡したとき、奇数バイトの中身の後に詰め物を書く" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var e: Encoder = try .init(&out.writer, .{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 3 });
    try e.writeRaw(&[_]u8{ 128, 129, 130 });
    try std.testing.expectEqual(null, try e.finish());
    const data = out.written();
    try std.testing.expectEqual(0, data[data.len - 1]);
    try std.testing.expectEqual(data.len - 8, std.mem.readInt(u32, data[4..8], .little));
    try std.testing.expectEqual(3, (try parse.Wav.parse(data)).frames());
}

test "Encoder.fileLen は書いた大きさと同じ" {
    for ([_]Options{
        .{ .sample_rate = 44100, .channels = 2, .frames = 1001 },
        .{ .sample_rate = 8000, .channels = 1, .format = .u8, .frames = 3 }, // 詰め物あり
        .{ .sample_rate = 48000, .channels = 3, .format = .i24, .frames = 5 }, // EXTENSIBLE
        .{ .sample_rate = 22050, .channels = 1, .format = .f64, .frames = 0 },
    }) |o| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var e: Encoder = try .init(&out.writer, o);
        const zeros = try std.testing.allocator.alloc(u8, @intCast(o.frames.? * e.frameLen()));
        defer std.testing.allocator.free(zeros);
        @memset(zeros, 0);
        try e.writeRaw(zeros);
        _ = try e.finish();
        try std.testing.expectEqual(out.written().len, try Encoder.fileLen(o));
    }
    try std.testing.expectError(error.TooLarge, Encoder.fileLen(.{ .sample_rate = 44100, .channels = 2, .format = .f64, .frames = 1 << 30 }));
    try std.testing.expectError(error.InvalidOptions, Encoder.fileLen(.{ .sample_rate = 0, .channels = 2, .frames = 1 }));
}

test "Encoder: エラー" {
    var discard: Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.InvalidOptions, Encoder.init(&discard.writer, .{ .sample_rate = 0, .channels = 2 }));
    // 1 フレームが 65535 バイトを超える(f64 で 8192 チャンネル)
    try std.testing.expectError(error.InvalidOptions, Encoder.init(&discard.writer, .{ .sample_rate = 44100, .channels = 8192, .format = .f64 }));
    _ = try Encoder.init(&discard.writer, .{ .sample_rate = 44100, .channels = 8191, .format = .f64 });
    // nAvgBytesPerSec が 32bit に収まらない
    try std.testing.expectError(error.InvalidOptions, Encoder.init(&discard.writer, .{ .sample_rate = 0xFFFF_FFFF, .channels = 2 }));
    try std.testing.expectError(error.TooLarge, Encoder.init(&discard.writer, .{ .sample_rate = 44100, .channels = 2, .frames = 1 << 30 }));
    var e: Encoder = try .init(&discard.writer, .{ .sample_rate = 44100, .channels = 2, .frames = 10 });
    try e.writeF32(&[_]f32{ 0, 0 });
    try std.testing.expectError(error.LengthMismatch, e.finish());
}
