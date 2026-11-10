// SPDX-License-Identifier: MIT
//! Ogg Opus(RFC 7845)の ID ヘッダの読み取りと、Opus パケット(RFC 6716)の長さ。
const std = @import("std");

pub const Error = error{ InvalidOgg, UnsupportedFormat };

/// Opus のデコード結果のサンプルレート(グラニュール位置もこの単位)
pub const sample_rate = 48000;

pub const Head = struct {
    channels: u8,
    /// 先頭で捨てるサンプル数(48kHz)
    pre_skip: u16,
    /// エンコード前の音源のサンプルレート(0 は不明)。デコードには使わない
    input_sample_rate: u32,
    /// チャンネルの割り当て方(0: モノラル / ステレオ、1: Vorbis の並び、255: 割り当てなし)
    mapping_family: u8,
};

/// ID ヘッダ(`OpusHead`)を読む
pub fn head(packet: []const u8) Error!Head {
    if (packet.len < 19 or !std.mem.eql(u8, packet[0..8], "OpusHead")) return error.InvalidOgg;
    // 上位 4 ビットが 0 の版だけ扱う(下位は互換のある改訂)
    if (packet[8] >> 4 != 0) return error.UnsupportedFormat;
    const channels = packet[9];
    const family = packet[18];
    if (channels == 0) return error.InvalidOgg;
    if (family == 0 and channels > 2) return error.InvalidOgg;
    if (family != 0) {
        // ストリーム数、結合したストリーム数、チャンネルの割り当て表
        if (packet.len < 21 + @as(usize, channels)) return error.InvalidOgg;
        const streams = packet[19];
        const coupled = packet[20];
        if (streams == 0 or coupled > streams) return error.InvalidOgg;
    }
    return .{
        .channels = channels,
        .pre_skip = std.mem.readInt(u16, packet[10..12], .little),
        .input_sample_rate = std.mem.readInt(u32, packet[12..16], .little),
        .mapping_family = family,
    };
}

/// パケットの長さ(48kHz のサンプル数)。`toc` は先頭のバイト、`count` は 2 バイト目(フレーム数が
/// 書いてある符号 3 のときだけ使う)。空のパケットは 0。壊れた(120ms を超える)パケットは null
pub fn packetSamples(len: usize, toc: u8, count: u8) ?u32 {
    if (len == 0) return 0;
    const config = toc >> 3;
    const frame: u32 = if (config < 12)
        ([_]u32{ 480, 960, 1920, 2880 })[config & 3]
    else if (config < 16)
        ([_]u32{ 480, 960 })[config & 1]
    else
        ([_]u32{ 120, 240, 480, 960 })[config & 3];
    const frames: u32 = switch (toc & 3) {
        0 => 1,
        1, 2 => 2,
        else => if (len < 2) return null else count & 0x3F,
    };
    const total = frame * frames;
    if (total > 5760) return null;
    return total;
}

test head {
    var h = "OpusHead\x01\x02\x38\x01\x44\xAC\x00\x00\x00\x00\x00".*;
    const got = try head(&h);
    try std.testing.expectEqual(2, got.channels);
    try std.testing.expectEqual(312, got.pre_skip);
    try std.testing.expectEqual(44100, got.input_sample_rate);
    h[8] = 0x10;
    try std.testing.expectError(error.UnsupportedFormat, head(&h));
    h[8] = 1;
    h[9] = 3;
    try std.testing.expectError(error.InvalidOgg, head(&h));
}

test packetSamples {
    // CELT 20ms 1 フレーム
    try std.testing.expectEqual(960, packetSamples(10, 31 << 3, 0).?);
    // SILK 60ms 2 フレーム
    try std.testing.expectEqual(5760, packetSamples(10, (3 << 3) | 1, 0).?);
    // CELT 2.5ms、符号 3 で 4 フレーム
    try std.testing.expectEqual(480, packetSamples(10, (16 << 3) | 3, 4).?);
    // 120ms を超える
    try std.testing.expectEqual(null, packetSamples(10, (3 << 3) | 3, 3));
    try std.testing.expectEqual(0, packetSamples(0, 0, 0).?);
}
