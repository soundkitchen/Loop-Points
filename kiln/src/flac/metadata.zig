// SPDX-License-Identifier: MIT
//! FLAC のストリームの先頭(`fLaC` とメタデータブロック。RFC 9639 §8)の解析。
const std = @import("std");
const id3 = @import("../mp3/id3.zig");

pub const Error = error{
    /// FLAC ではない
    NotFlac,
    /// FLAC だが扱えない(Ogg FLAC)
    UnsupportedFormat,
    /// メタデータが壊れている(STREAMINFO がない・先頭にない、ブロックの長さが入力を超えるなど)
    InvalidFlac,
};

/// メタデータブロックの種類
pub const BlockType = enum(u7) {
    stream_info = 0,
    padding = 1,
    application = 2,
    seek_table = 3,
    vorbis_comment = 4,
    cue_sheet = 5,
    picture = 6,
    _,
};

pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    /// 0 なら不明
    min_frame_size: u24,
    max_frame_size: u24,
    sample_rate: u32,
    channels: u8,
    bits: u8,
    /// 0 なら不明
    total_samples: u64,
    /// 復号した PCM の MD5。すべて 0 なら不明
    md5: [16]u8,

    pub const len = 34;

    fn parse(b: *const [len]u8) StreamInfo {
        const v = std.mem.readInt(u64, b[10..18], .big);
        return .{
            .min_block_size = std.mem.readInt(u16, b[0..2], .big),
            .max_block_size = std.mem.readInt(u16, b[2..4], .big),
            .min_frame_size = std.mem.readInt(u24, b[4..7], .big),
            .max_frame_size = std.mem.readInt(u24, b[7..10], .big),
            // サンプルレート(20) チャンネル数 - 1(3) ビット深度 - 1(5) 総サンプル数(36)
            .sample_rate = @intCast(v >> 44),
            .channels = @as(u8, @intCast((v >> 41) & 7)) + 1,
            .bits = @as(u8, @intCast((v >> 36) & 31)) + 1,
            .total_samples = v & ((1 << 36) - 1),
            .md5 = b[18..34].*,
        };
    }
};

pub const Metadata = struct {
    /// `fLaC` の位置(先頭の ID3v2 タグを除いた位置)
    start: usize,
    info: StreamInfo,
    /// 最初のフレームの位置(メタデータブロックの直後)
    frames_start: usize,

    /// `input` の先頭(ID3v2 タグがあれば読み飛ばす)の `fLaC` とメタデータブロックを解析する
    pub fn parse(input: []const u8) Error!Metadata {
        const start = id3.skipTags(input);
        const rest = input[start..];
        if (rest.len >= 4 and std.mem.eql(u8, rest[0..4], "OggS")) {
            // Ogg FLAC(最初のページのパケットが 0x7F "FLAC" で始まる)
            if (rest.len >= 33 and std.mem.eql(u8, rest[28..33], "\x7FFLAC")) return error.UnsupportedFormat;
            return error.NotFlac;
        }
        if (rest.len < 4 or !std.mem.eql(u8, rest[0..4], "fLaC")) return error.NotFlac;

        var it: BlockIterator = .{ .input = input, .pos = start + 4, .end = input.len };
        var info: ?StreamInfo = null;
        while (true) {
            const b = it.next() orelse return error.InvalidFlac;
            if (@backingInt(b.kind) == 127) return error.InvalidFlac;
            // STREAMINFO は最初のブロックで、1 つだけ
            if ((info == null) != (b.kind == .stream_info)) return error.InvalidFlac;
            if (b.kind == .stream_info) {
                if (b.body.len != StreamInfo.len) return error.InvalidFlac;
                info = .parse(b.body[0..StreamInfo.len]);
            }
            if (b.last) break;
        }
        const si = info.?;
        if (si.sample_rate == 0 or si.bits < 4) return error.InvalidFlac;
        return .{ .start = start, .info = si, .frames_start = it.pos };
    }

    /// 先頭(ID3v2 タグがあればその後)の `fLaC` に続く STREAMINFO だけを読む。ほかのメタデータブロックは
    /// 見ないので、後ろが壊れた FLAC でも、入力がファイルの先頭の一部でも読める。FLAC でない(Ogg FLAC も)、
    /// 最初のブロックが STREAMINFO でない、入力に収まらないときは null
    pub fn streamInfo(input: []const u8) ?StreamInfo {
        const rest = input[id3.skipTags(input)..];
        if (rest.len < 8 + StreamInfo.len or !std.mem.eql(u8, rest[0..4], "fLaC")) return null;
        if (rest[4] & 0x7F != 0 or std.mem.readInt(u24, rest[5..8], .big) != StreamInfo.len) return null;
        return .parse(rest[8..][0..StreamInfo.len]);
    }

    /// メタデータブロックを順にたどる(`parse` が確かめた後なので、どのブロックも入力に収まる)
    pub fn blocks(m: Metadata, input: []const u8) BlockIterator {
        return .{ .input = input, .pos = m.start + 4, .end = m.frames_start };
    }
};

pub const Block = struct {
    kind: BlockType,
    /// 最後のメタデータブロックか
    last: bool,
    body: []const u8,
};

/// メタデータブロックを先頭から順にたどる。ヘッダや中身が `end` を超えるところで終わる(null)
pub const BlockIterator = struct {
    input: []const u8,
    pos: usize,
    end: usize,

    pub fn next(it: *BlockIterator) ?Block {
        if (it.pos >= it.end or it.end - it.pos < 4) return null;
        const h = it.input[it.pos..][0..4];
        const len = std.mem.readInt(u24, h[1..4], .big);
        if (it.end - it.pos - 4 < len) return null;
        const b: Block = .{
            .kind = @fromBackingInt(@intCast(h[0] & 0x7F)),
            .last = h[0] & 0x80 != 0,
            .body = it.input[it.pos + 4 ..][0..len],
        };
        it.pos += 4 + @as(usize, len);
        return b;
    }
};

/// テスト用: STREAMINFO のバイト列を作る
pub fn testStreamInfo(sample_rate: u32, channels: u8, bits: u8, total: u64) [StreamInfo.len]u8 {
    var b: [StreamInfo.len]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], 4096, .big);
    std.mem.writeInt(u16, b[2..4], 4096, .big);
    const v: u64 = (@as(u64, sample_rate) << 44) | (@as(u64, channels - 1) << 41) | (@as(u64, bits - 1) << 36) | total;
    std.mem.writeInt(u64, b[10..18], v, .big);
    return b;
}

test "Metadata.parse" {
    const si = testStreamInfo(44100, 2, 16, 12345);
    // fLaC、STREAMINFO、最後のブロックとして PADDING(3 バイト)
    const input = "fLaC" ++ "\x00\x00\x00\x22" ++ si ++ "\x81\x00\x00\x03" ++ "\x00\x00\x00" ++ "\xFF\xF8";
    const m = try Metadata.parse(input);
    try std.testing.expectEqual(0, m.start);
    try std.testing.expectEqual(44100, m.info.sample_rate);
    try std.testing.expectEqual(2, m.info.channels);
    try std.testing.expectEqual(16, m.info.bits);
    try std.testing.expectEqual(12345, m.info.total_samples);
    try std.testing.expectEqual(input.len - 2, m.frames_start);

    // 先頭の ID3v2 タグは読み飛ばす
    const tagged = "ID3\x04\x00\x00\x00\x00\x00\x02ab" ++ input;
    try std.testing.expectEqual(12, (try Metadata.parse(tagged)).start);

    try std.testing.expectError(error.NotFlac, Metadata.parse("RIFF"));
    try std.testing.expectError(error.NotFlac, Metadata.parse(""));
    try std.testing.expectError(error.UnsupportedFormat, Metadata.parse("OggS" ++ @as([24]u8, @splat(0)) ++ "\x7FFLAC"));
    // STREAMINFO がない・先頭にない・2 つある、長さが違う、ブロックが入力を超える、最後のブロックがない
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x81\x00\x00\x00"));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x01\x00\x00\x00" ++ "\x80\x00\x00\x22" ++ si));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x00\x00\x00\x22" ++ si ++ "\x80\x00\x00\x22" ++ si));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x80\x00\x00\x21" ++ si[0..33]));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x80\x00\x00\x22" ++ si[0..20]));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x00\x00\x00\x22" ++ si));
    // サンプルレート 0、ビット深度 3
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x80\x00\x00\x22" ++ testStreamInfo(0, 2, 16, 0)));
    try std.testing.expectError(error.InvalidFlac, Metadata.parse("fLaC" ++ "\x80\x00\x00\x22" ++ testStreamInfo(44100, 2, 3, 0)));
}
