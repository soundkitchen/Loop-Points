// SPDX-License-Identifier: MIT
//! FLAC のフレームヘッダ(RFC 9639 §9.1)の解析。
const std = @import("std");

pub const Crc8 = std.hash.crc.@"CRC-8/SMBUS";
pub const Crc16 = std.hash.crc.@"CRC-16/UMTS";

/// ステレオの相関除去の種類(RFC 9639 §4.2)
pub const Assignment = enum {
    /// チャンネルごとに独立
    independent,
    /// 左と side(右 = 左 - side)
    left_side,
    /// side と右(左 = side + 右)
    side_right,
    /// mid と side
    mid_side,
};

pub const Header = struct {
    /// 可変ブロック長(番号がサンプル位置)。false なら固定ブロック長(番号がフレーム番号)
    variable: bool,
    /// ブロック長(チャンネルあたりのサンプル数。1〜65536)
    block_size: u32,
    /// サンプルレート。0 なら STREAMINFO の値
    sample_rate: u32,
    channels: u8,
    assignment: Assignment,
    /// ビット深度。0 なら STREAMINFO の値
    bits: u8,
    /// フレーム番号またはサンプル位置
    number: u64,
    /// ヘッダのバイト数(CRC-8 を含む)
    len: usize,

    /// `bytes` の先頭のフレームヘッダを解析する。同期コード・予約値・CRC-8 のどれかがおかしければ null
    pub fn parse(bytes: []const u8) ?Header {
        if (bytes.len < 6) return null;
        // 同期コード(15 ビット)と予約ビット(0)、ブロック長の方式
        if (bytes[0] != 0xFF or bytes[1] & 0xFE != 0xF8) return null;
        const variable = bytes[1] & 1 == 1;
        const bs_code = bytes[2] >> 4;
        const sr_code = bytes[2] & 0x0F;
        const ch_code = bytes[3] >> 4;
        const bits_code = (bytes[3] >> 1) & 7;
        if (bs_code == 0 or sr_code == 15 or ch_code > 10 or bits_code == 3 or bytes[3] & 1 != 0) return null;

        // フレーム番号またはサンプル位置(UTF-8 に似た可変長の符号)
        var pos: usize = 4;
        const number = readCodedNumber(bytes, &pos, variable) orelse return null;

        const block_size: u32 = switch (bs_code) {
            1 => 192,
            2...5 => @as(u32, 576) << @intCast(bs_code - 2),
            6 => blk: {
                if (bytes.len < pos + 1) return null;
                pos += 1;
                break :blk @as(u32, bytes[pos - 1]) + 1;
            },
            7 => blk: {
                if (bytes.len < pos + 2) return null;
                pos += 2;
                break :blk @as(u32, std.mem.readInt(u16, bytes[pos - 2 ..][0..2], .big)) + 1;
            },
            else => @as(u32, 256) << @intCast(bs_code - 8),
        };
        const sample_rate: u32 = switch (sr_code) {
            0 => 0,
            1 => 88200,
            2 => 176400,
            3 => 192000,
            4 => 8000,
            5 => 16000,
            6 => 22050,
            7 => 24000,
            8 => 32000,
            9 => 44100,
            10 => 48000,
            11 => 96000,
            12 => blk: {
                if (bytes.len < pos + 1) return null;
                pos += 1;
                break :blk @as(u32, bytes[pos - 1]) * 1000;
            },
            13, 14 => blk: {
                if (bytes.len < pos + 2) return null;
                pos += 2;
                const v: u32 = std.mem.readInt(u16, bytes[pos - 2 ..][0..2], .big);
                break :blk if (sr_code == 13) v else v * 10;
            },
            else => unreachable,
        };
        // 明示したサンプルレートが 0 なのは不正
        if (sr_code >= 12 and sample_rate == 0) return null;
        const bits: u8 = switch (bits_code) {
            0 => 0,
            1 => 8,
            2 => 12,
            4 => 16,
            5 => 20,
            6 => 24,
            7 => 32,
            else => unreachable,
        };

        if (bytes.len < pos + 1) return null;
        if (Crc8.hash(bytes[0..pos]) != bytes[pos]) return null;
        pos += 1;

        return .{
            .variable = variable,
            .block_size = block_size,
            .sample_rate = sample_rate,
            .channels = if (ch_code < 8) ch_code + 1 else 2,
            .assignment = switch (ch_code) {
                8 => .left_side,
                9 => .side_right,
                10 => .mid_side,
                else => .independent,
            },
            .bits = bits,
            .number = number,
            .len = pos,
        };
    }
};

/// フレーム番号(固定ブロック長、31 ビットまで)またはサンプル位置(可変ブロック長、36 ビットまで)を読む
fn readCodedNumber(bytes: []const u8, pos: *usize, variable: bool) ?u64 {
    const b0 = bytes[pos.*];
    // 先頭の 1 の数がバイト数(0 個なら 1 バイト)
    const ones: u4 = @clz(~b0);
    const n: usize = switch (ones) {
        0 => 1,
        1 => return null, // 継続バイトから始まっている
        else => ones,
    };
    if (n > @as(usize, if (variable) 7 else 6)) return null;
    if (bytes.len < pos.* + n) return null;
    var v: u64 = if (n == 1) b0 else b0 & (@as(u8, 0x7F) >> @intCast(n));
    for (bytes[pos.* + 1 .. pos.* + n]) |b| {
        if (b & 0xC0 != 0x80) return null;
        v = (v << 6) | (b & 0x3F);
    }
    pos.* += n;
    return v;
}

test "Header.parse" {
    // 固定ブロック長 4096、44.1kHz、left/side、16bit、フレーム番号 0
    var h: [6]u8 = .{ 0xFF, 0xF8, 0xC9, 0x88, 0x00, 0 };
    h[5] = Crc8.hash(h[0..5]);
    const p = Header.parse(&h).?;
    try std.testing.expectEqual(false, p.variable);
    try std.testing.expectEqual(4096, p.block_size);
    try std.testing.expectEqual(44100, p.sample_rate);
    try std.testing.expectEqual(2, p.channels);
    try std.testing.expectEqual(Assignment.left_side, p.assignment);
    try std.testing.expectEqual(16, p.bits);
    try std.testing.expectEqual(0, p.number);
    try std.testing.expectEqual(6, p.len);

    // CRC-8 が違う
    h[5] ^= 1;
    try std.testing.expectEqual(null, Header.parse(&h));

    // 可変ブロック長、ブロック長は 16 ビットで 1000、サンプルレートは 16 ビット(Hz)で 39000、
    // 6 チャンネル独立、ビット深度は STREAMINFO、サンプル位置 0xABCD(3 バイトの符号: 4 + 6 + 6 ビット)
    var v: [12]u8 = .{ 0xFF, 0xF9, 0x7D, 0x50, 0xE0 | 0xA, 0x80 | (0xABCD >> 6 & 0x3F), 0x80 | (0xABCD & 0x3F), 0x03, 0xE7, 0x98, 0x58, 0 };
    v[11] = Crc8.hash(v[0..11]);
    const q = Header.parse(&v).?;
    try std.testing.expectEqual(true, q.variable);
    try std.testing.expectEqual(1000, q.block_size);
    try std.testing.expectEqual(39000, q.sample_rate);
    try std.testing.expectEqual(6, q.channels);
    try std.testing.expectEqual(Assignment.independent, q.assignment);
    try std.testing.expectEqual(0, q.bits);
    try std.testing.expectEqual(0xABCD, q.number);
    try std.testing.expectEqual(12, q.len);

    // 予約値: ブロック長 0、サンプルレート 15、チャンネル 11、ビット深度 3、予約ビット
    for ([_][2]u8{ .{ 2, 0x09 }, .{ 2, 0xCF }, .{ 3, 0xB8 }, .{ 3, 0x86 }, .{ 3, 0x89 } }) |m| {
        var x: [6]u8 = .{ 0xFF, 0xF8, 0xC9, 0x88, 0x00, 0 };
        x[m[0]] = m[1];
        x[5] = Crc8.hash(x[0..5]);
        try std.testing.expectEqual(null, Header.parse(&x));
    }
    // 同期コードの後の予約ビット
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xFA, 0xC9, 0x88, 0x00, 0x00 }));
}
