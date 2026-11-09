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
    /// または free format などで扱えないものは null
    pub fn parse(bytes: []const u8) ?Header {
        if (bytes.len < 4 or !isSync(bytes)) return null;
        const h: Header = .{ .raw = std.mem.readInt(u32, bytes[0..4], .big) };
        if (h.field(19, 2) != 0b11) return null; // MPEG-1
        if (h.field(17, 2) != 0b01) return null; // Layer III
        const bi = h.bitrateIndex();
        if (bi == 0 or bi == 15) return null;
        if (h.field(10, 2) == 0b11) return null; // サンプルレートの予約値
        if (h.field(0, 2) == 0b10) return null; // emphasis の予約値
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

test "Header.forInfoFrame" {
    const h = Header.parse(&.{ 0xFF, 0xFA, 0xB2, 0x64 }).?; // CRC あり、padding あり
    const info = h.forInfoFrame(5);
    try std.testing.expectEqual(64, info.bitrate());
    try std.testing.expect(!info.hasPadding());
    try std.testing.expect(!info.hasCrc());
    try std.testing.expectEqual(h.sampleRate(), info.sampleRate());
    try std.testing.expectEqual(h.isMono(), info.isMono());
}
