//! WAV のヘッダ(RIFF ヘッダ、`fmt ` チャンク、`data` チャンクのヘッダ)の書き出し。
const std = @import("std");
const Io = std.Io;

/// RIFF ヘッダから `data` チャンクのヘッダまでのバイト数
pub fn len(fmt_chunk: []const u8) usize {
    return 12 + 8 + fmt_chunk.len + fmt_chunk.len % 2 + 8;
}

/// RIFF のサイズフィールドに入る値。収まらなければ null
pub fn riffSize(fmt_chunk: []const u8, data_len: u64) ?u32 {
    const total = 4 + 8 + @as(u64, fmt_chunk.len) + fmt_chunk.len % 2 + 8 + data_len + data_len % 2;
    return std.math.cast(u32, total);
}

/// ヘッダを書く。`data_len` は `data` チャンクの中身のバイト数で、`riffSize` が null にならないこと。
/// `data` の中身と、中身が奇数バイトのときの詰め物の 1 バイトは呼び出し側が書く
pub fn write(w: *Io.Writer, fmt_chunk: []const u8, data_len: u32) Io.Writer.Error!void {
    try writeSizes(w, fmt_chunk, riffSize(fmt_chunk, data_len).?, data_len);
}

/// サイズフィールドの値を指定してヘッダを書く(長さが分からないときに 0xFFFFFFFF を入れるため)
pub fn writeSizes(w: *Io.Writer, fmt_chunk: []const u8, riff_size: u32, data_len: u32) Io.Writer.Error!void {
    try w.writeAll("RIFF");
    try w.writeInt(u32, riff_size, .little);
    try w.writeAll("WAVE" ++ "fmt ");
    try w.writeInt(u32, @intCast(fmt_chunk.len), .little);
    try w.writeAll(fmt_chunk);
    if (fmt_chunk.len % 2 == 1) try w.writeByte(0);
    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
}

test write {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const fmt_chunk = "\x01\x00\x02\x00\x44\xAC\x00\x00\x10\xB1\x02\x00\x04\x00\x10\x00";
    try write(&w, fmt_chunk, 8);
    try std.testing.expectEqual(len(fmt_chunk), w.end);
    try std.testing.expectEqualSlices(u8, "RIFF\x2C\x00\x00\x00WAVEfmt \x10\x00\x00\x00" ++ fmt_chunk ++ "data\x08\x00\x00\x00", w.buffered());
    try std.testing.expectEqual(null, riffSize(fmt_chunk, 0xFFFF_FFFF));
}
