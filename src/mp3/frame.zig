// SPDX-License-Identifier: MIT
//! MPEG-1 Layer III のフレームヘッダとサイド情報の解析。
//! 扱うのは MPEG-1 Layer III だけ(1 フレーム 1152 サンプル)。
const std = @import("std");

/// 1 フレームあたりのサンプル数(MPEG-1 Layer III)
pub const samples_per_frame = 1152;

/// MPEG-1 Layer III のビットレート(kbps)。添字はヘッダの bitrate index。
/// 0(free format)と 15(不正)は扱わない
const bitrates = [15]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
const sample_rates = [3]u32{ 44100, 48000, 32000 };

/// フレームの最大長(320kbps、32kHz、padding あり)
pub const max_frame_len = 144 * 320_000 / 32_000 + 1;

/// 先頭 11 ビットがフレーム同期(すべて 1)かどうか
pub fn isSync(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] & 0xE0 == 0xE0;
}

pub const Header = struct {
    /// ヘッダの 4 バイト(ビッグエンディアン)
    raw: u32,

    /// MPEG-1 Layer III の有効なヘッダなら返す。同期はあっても MPEG-1 Layer III でない、
    /// または free format などで扱えないものは null。emphasis は見ない
    pub fn parse(bytes: []const u8) ?Header {
        if (bytes.len < 4 or !isSync(bytes)) return null;
        const h: Header = .{ .raw = std.mem.readInt(u32, bytes[0..4], .big) };
        if (h.field(19, 2) != 0b11) return null; // MPEG-1
        if (h.field(17, 2) != 0b01) return null; // Layer III
        const bi = h.bitrateIndex();
        if (bi == 0 or bi == 15) return null;
        if (h.field(10, 2) == 0b11) return null; // サンプルレートの予約値
        // emphasis(予約値の 2 を含む)は音声データに関係しないので見ない(ffmpeg と同じ)。
        // 最初のフレームを探すときだけ、予約値を候補から外す(stream.findFirstFrame)
        return h;
    }

    fn field(h: Header, comptime shift: u5, comptime bits: u5) u32 {
        return (h.raw >> shift) & ((@as(u32, 1) << bits) - 1);
    }

    pub fn bitrateIndex(h: Header) u4 {
        return @intCast(h.field(12, 4));
    }

    /// ビットレート(kbps)
    pub fn bitrate(h: Header) u32 {
        return bitrates[h.bitrateIndex()];
    }

    pub fn sampleRate(h: Header) u32 {
        return sample_rates[h.field(10, 2)];
    }

    /// サンプルレートの番号(0: 44.1kHz、1: 48kHz、2: 32kHz)。スケールファクタ帯の表を引くのに使う
    pub fn sampleRateIndex(h: Header) u2 {
        return @intCast(h.field(10, 2));
    }

    pub fn hasPadding(h: Header) bool {
        return h.field(9, 1) == 1;
    }

    /// ヘッダの直後に CRC(2 バイト)があるか(protection bit が 0 のとき)
    pub fn hasCrc(h: Header) bool {
        return h.field(16, 1) == 0;
    }

    pub fn isMono(h: Header) bool {
        return h.field(6, 2) == 0b11;
    }

    /// チャンネルモード(0: ステレオ、1: ジョイントステレオ、2: デュアルチャンネル、3: モノラル)
    pub fn mode(h: Header) u2 {
        return @intCast(h.field(6, 2));
    }

    /// モード拡張(ジョイントステレオのとき。ビット 1 が MS ステレオ、ビット 0 がインテンシティステレオ)。
    /// ジョイントステレオでなければ 0
    pub fn modeExtension(h: Header) u2 {
        return if (h.mode() == 1) @intCast(h.field(4, 2)) else 0;
    }

    pub fn channels(h: Header) u8 {
        return if (h.isMono()) 1 else 2;
    }

    /// サイド情報のバイト数
    pub fn sideInfoLen(h: Header) usize {
        return if (h.isMono()) 17 else 32;
    }

    /// フレーム全体のバイト数(ヘッダを含む)
    pub fn frameLen(h: Header) usize {
        return frameLenFor(h.bitrateIndex(), h.sampleRate(), h.hasPadding());
    }

    /// フレームのうち、メインデータ(ビットリザーバとして後続フレームも使う領域)のバイト数
    pub fn mainDataLen(h: Header) usize {
        return h.frameLen() - 4 - @as(usize, if (h.hasCrc()) 2 else 0) - h.sideInfoLen();
    }

    /// フレームのメインデータ領域。`frame` はフレーム全体
    pub fn mainData(h: Header, frame: []const u8) []const u8 {
        return frame[frame.len - h.mainDataLen() ..];
    }

    /// サイド情報の main_data_begin(このフレームのメインデータが、前のフレームの
    /// メインデータ領域の終わりから何バイト前に始まるか)。`frame` はフレームの先頭から
    pub fn mainDataBegin(h: Header, frame: []const u8) u16 {
        const p: usize = 4 + @as(usize, if (h.hasCrc()) 2 else 0);
        return (@as(u16, frame[p]) << 1) | (frame[p + 1] >> 7);
    }

    /// 同じストリームのフレームとして混在してよいか(サンプルレートとチャンネル数が同じ)
    pub fn compatible(h: Header, other: Header) bool {
        return h.sampleRate() == other.sampleRate() and h.isMono() == other.isMono();
    }

    /// ビットレートを差し替え、padding なし・CRC なしにしたヘッダ。Info フレーム用
    pub fn forInfoFrame(h: Header, bitrate_index: u4) Header {
        var raw = h.raw;
        raw &= ~(@as(u32, 0xF) << 12);
        raw |= @as(u32, bitrate_index) << 12;
        raw &= ~(@as(u32, 1) << 9); // padding なし
        raw |= @as(u32, 1) << 16; // protection bit = 1(CRC なし)
        return .{ .raw = raw };
    }
};

/// ビットレート・サンプルレート・padding の有無からフレーム長を求める
pub fn frameLenFor(bitrate_index: u4, sample_rate: u32, padding: bool) usize {
    return 144 * @as(usize, bitrates[bitrate_index]) * 1000 / sample_rate + @intFromBool(padding);
}

/// MPEG オーディオ全般(MPEG-1 / 2 / 2.5、Layer I / II / III)のフレームヘッダ。
/// 扱わない形式のファイルを「MP3 ではない」ではなく「対応していない形式」と報告するために、
/// フレームの長さと形式だけを読む
pub const AnyHeader = struct {
    /// フレーム全体のバイト数(ヘッダを含む)
    len: usize,
    /// 同じストリームのフレームか比べるための値(バージョン・レイヤー・サンプルレートのビット)
    kind: u32,

    /// [バージョン(0: MPEG-1、1: MPEG-2 / 2.5)][レイヤー(0: I、1: II、2: III)] のビットレート(kbps)
    const any_bitrates = [2][3][15]u16{
        .{
            .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
            .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
            bitrates,
        },
        .{
            .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
            .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
            .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
        },
    };

    /// MPEG オーディオの有効なヘッダなら返す(free format と予約値は null。emphasis は見ない)
    pub fn parse(bytes: []const u8) ?AnyHeader {
        if (bytes.len < 4 or !isSync(bytes)) return null;
        const raw = std.mem.readInt(u32, bytes[0..4], .big);
        const version: u2 = @intCast((raw >> 19) & 3); // 0: 2.5、1: 予約、2: MPEG-2、3: MPEG-1
        const layer_bits: u2 = @intCast((raw >> 17) & 3); // 0: 予約、1: III、2: II、3: I
        const bi: u4 = @intCast((raw >> 12) & 0xF);
        const sri: u2 = @intCast((raw >> 10) & 3);
        if (version == 1 or layer_bits == 0 or bi == 0 or bi == 15 or sri == 3) return null;
        const layer: usize = 3 - @as(usize, layer_bits); // 0: I、1: II、2: III
        const mpeg1 = version == 3;
        const kbps: usize = any_bitrates[@intFromBool(!mpeg1)][layer][bi];
        const sr = sample_rates[sri] >> switch (version) {
            3 => 0,
            2 => 1,
            else => 2,
        };
        const padding: usize = (raw >> 9) & 1;
        const len = switch (layer) {
            0 => (12 * kbps * 1000 / sr + padding) * 4,
            1 => 144 * kbps * 1000 / sr + padding,
            else => (if (mpeg1) @as(usize, 144) else 72) * kbps * 1000 / sr + padding,
        };
        return .{ .len = len, .kind = raw & 0x001E0C00 };
    }
};

/// 連続するフレームを先頭から順にたどる
pub const Iterator = struct {
    data: []const u8,
    pos: usize,

    pub const Frame = struct {
        offset: usize,
        header: Header,

        pub fn bytes(f: Frame, data: []const u8) []const u8 {
            return data[f.offset..][0..f.header.frameLen()];
        }
    };

    /// 次のフレーム。有効なヘッダがない、またはフレームが途中で切れていたら null
    pub fn next(it: *Iterator) ?Frame {
        const h = Header.parse(it.data[it.pos..]) orelse return null;
        const len = h.frameLen();
        if (it.data.len - it.pos < len) return null;
        const f: Frame = .{ .offset = it.pos, .header = h };
        it.pos += len;
        return f;
    }
};

test "Header.parse: MPEG-1 Layer III 192kbps 44.1kHz joint stereo" {
    const h = Header.parse(&.{ 0xFF, 0xFB, 0xB0, 0x64 }).?;
    try std.testing.expectEqual(192, h.bitrate());
    try std.testing.expectEqual(44100, h.sampleRate());
    try std.testing.expectEqual(626, h.frameLen());
    try std.testing.expect(!h.hasCrc());
    try std.testing.expectEqual(2, h.channels());
    try std.testing.expectEqual(626 - 4 - 32, h.mainDataLen());
}

test "Header.parse: 扱えないヘッダは null" {
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xF3, 0xB0, 0x64 })); // MPEG-2
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xFD, 0xB0, 0x64 })); // Layer II
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xFB, 0x00, 0x64 })); // free format
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xFB, 0xBC, 0x64 })); // 予約サンプルレート
    try std.testing.expectEqual(null, Header.parse(&.{ 0x54, 0x41, 0x47, 0x00 })); // "TAG"
    try std.testing.expectEqual(null, Header.parse(&.{ 0xFF, 0xFB }));
}

test "AnyHeader.parse" {
    // MPEG-1 Layer III は Header と同じ長さ
    try std.testing.expectEqual(626, AnyHeader.parse(&.{ 0xFF, 0xFB, 0xB0, 0x64 }).?.len);
    // MPEG-2 Layer III 80kbps 22.05kHz: 72 * 80000 / 22050 = 261
    try std.testing.expectEqual(261, AnyHeader.parse(&.{ 0xFF, 0xF3, 0x90, 0x64 }).?.len);
    // MPEG-2.5 Layer III 8kbps 8kHz: 72 * 8000 / 8000 = 72
    try std.testing.expectEqual(72, AnyHeader.parse(&.{ 0xFF, 0xE3, 0x18, 0x64 }).?.len);
    // MPEG-1 Layer II 192kbps 48kHz: 144 * 192000 / 48000 = 576
    try std.testing.expectEqual(576, AnyHeader.parse(&.{ 0xFF, 0xFD, 0xA4, 0x04 }).?.len);
    // MPEG-1 Layer I 32kbps 44.1kHz、padding あり: (12 * 32000 / 44100 + 1) * 4 = 36
    try std.testing.expectEqual(36, AnyHeader.parse(&.{ 0xFF, 0xFF, 0x12, 0x04 }).?.len);
    // バージョンの予約値、レイヤーの予約値、free format
    try std.testing.expectEqual(null, AnyHeader.parse(&.{ 0xFF, 0xEB, 0x90, 0x64 }));
    try std.testing.expectEqual(null, AnyHeader.parse(&.{ 0xFF, 0xF9, 0x90, 0x64 }));
    try std.testing.expectEqual(null, AnyHeader.parse(&.{ 0xFF, 0xF3, 0x00, 0x64 }));
}

test "Header.forInfoFrame" {
    const h = Header.parse(&.{ 0xFF, 0xFA, 0xB2, 0x64 }).?; // CRC あり、padding あり
    const info = h.forInfoFrame(5);
    try std.testing.expectEqual(64, info.bitrate());
    try std.testing.expect(!info.hasPadding());
    try std.testing.expect(!info.hasCrc());
    try std.testing.expectEqual(h.sampleRate(), info.sampleRate());
    try std.testing.expectEqual(h.isMono(), info.isMono());
}
