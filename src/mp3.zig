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

test {
    _ = frame;
    _ = stream;
    _ = trim_impl;
    _ = @import("mp3/id3.zig");
    _ = @import("mp3/xing.zig");
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
