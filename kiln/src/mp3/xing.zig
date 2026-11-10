// SPDX-License-Identifier: MIT
//! 先頭フレームの Xing / Info / LAME / VBRI ヘッダの読み取りと、Info + LAME タグのフレームの生成。
const std = @import("std");
const Io = std.Io;
const frame = @import("frame.zig");
const Header = frame.Header;

const flag_frames = 0x1;
const flag_bytes = 0x2;
const flag_toc = 0x4;
const flag_quality = 0x8;

/// Xing 部(タグ 4 + フラグ 4 + frames 4 + bytes 4 + TOC 100 + quality 4)の長さ
const xing_len = 120;
/// LAME 部の長さ
const lame_len = 36;
/// LAME 部のうち、タグ自身の CRC-16 の位置
const lame_crc_offset = 34;

/// Xing 部の位置(フレーム先頭から)。ffmpeg と同じく、CRC の有無は考慮しない
fn xingOffset(h: Header) usize {
    return 4 + h.sideInfoLen();
}

/// 先頭フレームが音声ではなくヘッダ(Xing / Info / VBRI)だったときの中身
pub const Tag = struct {
    /// LAME タグのエンコーダ遅延とパディング。ffmpeg と同じく、エンコーダ名が
    /// LAME / Lavf / Lavc で始まるときだけ読む
    lame: ?struct { delay: u12, padding: u12 },
};

/// フレームが Xing / Info / VBRI ヘッダなら、その中身を返す。音声フレームなら null
pub fn parse(f: []const u8, h: Header) ?Tag {
    if (f.len >= 36 + 4 and std.mem.eql(u8, f[36..][0..4], "VBRI")) return .{ .lame = null };

    var p = xingOffset(h);
    if (f.len < p + 8) return null;
    const tag = f[p..][0..4];
    if (!std.mem.eql(u8, tag, "Xing") and !std.mem.eql(u8, tag, "Info")) return null;
    const flags = std.mem.readInt(u32, f[p + 4 ..][0..4], .big);
    p += 8;
    if (flags & flag_frames != 0) p += 4;
    if (flags & flag_bytes != 0) p += 4;
    if (flags & flag_toc != 0) p += 100;
    if (flags & flag_quality != 0) p += 4;

    if (f.len < p + 24) return .{ .lame = null };
    const lame = f[p..][0..24];
    const known = for ([_][]const u8{ "LAME", "Lavf", "Lavc" }) |name| {
        if (std.mem.startsWith(u8, lame, name)) break true;
    } else false;
    if (!known) return .{ .lame = null };
    return .{ .lame = .{
        .delay = @intCast((@as(u16, lame[21]) << 4) | (lame[22] >> 4)),
        .padding = @intCast((@as(u16, lame[22] & 0x0F) << 8) | lame[23]),
    } };
}

/// Info フレームに LAME タグまで収めるのに要るバイト数
pub fn infoFrameMinLen(h: Header) usize {
    return xingOffset(h) + xing_len + lame_len;
}

/// LAME タグに書くエンコーダ名(9 バイト固定。docs/draft.md §2.1)
pub const encoder_name = "LAMEK!LN ";

pub const InfoFrame = struct {
    /// Info フレームのヘッダ(`Header.forInfoFrame` で作ったもの)
    header: Header,
    /// "Info"(CBR)か "Xing"(VBR)か
    vbr: bool,
    /// 続く音声フレームの数(Info フレーム自身は数えない)
    frames: u32,
    /// Info フレームと続く音声フレームの合計バイト数
    bytes: u32,
    /// TOC。null なら CBR 用の線形な TOC を書く
    toc: ?*const [100]u8,
    delay: u12,
    padding: u12,
};

/// Info + LAME タグのフレームを書く(docs/lyria-mp3.md §4 の手順 3)
pub fn writeInfoFrame(w: *Io.Writer, info: InfoFrame) Io.Writer.Error!void {
    var buf: [frame.max_frame_len]u8 = @splat(0);
    const len = info.header.frameLen();
    std.debug.assert(len >= infoFrameMinLen(info.header));
    const f = buf[0..len];

    std.mem.writeInt(u32, f[0..4], info.header.raw, .big);
    // サイド情報はすべて 0(main_data_begin = 0、音声データなし)

    const x = xingOffset(info.header);
    @memcpy(f[x..][0..4], if (info.vbr) "Xing" else "Info");
    std.mem.writeInt(u32, f[x + 4 ..][0..4], flag_frames | flag_bytes | flag_toc | flag_quality, .big);
    std.mem.writeInt(u32, f[x + 8 ..][0..4], info.frames, .big);
    std.mem.writeInt(u32, f[x + 12 ..][0..4], info.bytes, .big);
    const toc = f[x + 16 ..][0..100];
    if (info.toc) |t| {
        toc.* = t.*;
    } else {
        for (toc, 0..) |*v, i| v.* = @intCast(i * 256 / 100);
    }
    // quality は 0

    // LAME 部。エンコーダ名と delay / padding 以外は 0(検証した形のまま)
    const l = x + xing_len;
    @memcpy(f[l..][0..9], encoder_name);
    f[l + 21] = @intCast(info.delay >> 4);
    f[l + 22] = @intCast(((info.delay & 0x0F) << 4) | (info.padding >> 8));
    f[l + 23] = @truncate(info.padding);
    // LAME タグの CRC-16: フレーム先頭から CRC の直前まで(ステレオなら 190 バイト)
    const crc_pos = l + lame_crc_offset;
    std.mem.writeInt(u16, f[crc_pos..][0..2], std.hash.crc.@"CRC-16/ARC".hash(f[0..crc_pos]), .big);

    try w.writeAll(f);
}

test "writeInfoFrame と parse の往復" {
    const audio = Header.parse(&.{ 0xFF, 0xFB, 0xB0, 0x64 }).?;
    const h = audio.forInfoFrame(audio.bitrateIndex());
    var buf: [frame.max_frame_len]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeInfoFrame(&w, .{
        .header = h,
        .vbr = false,
        .frames = 402,
        .bytes = 626 * 403,
        .toc = null,
        .delay = 2075,
        .padding = 1681,
    });
    const f = w.buffered();
    try std.testing.expectEqual(626, f.len);
    try std.testing.expectEqualStrings("Info", f[36..40]);
    try std.testing.expectEqualStrings(encoder_name, f[156..165]);
    try std.testing.expectEqual(0, h.mainDataBegin(f));
    // CRC は先頭 190 バイトに対するもの
    try std.testing.expectEqual(std.hash.crc.@"CRC-16/ARC".hash(f[0..190]), std.mem.readInt(u16, f[190..192], .big));

    const tag = parse(f, h).?;
    try std.testing.expectEqual(2075, tag.lame.?.delay);
    try std.testing.expectEqual(1681, tag.lame.?.padding);
}

test "parse: 音声フレームと、エンコーダ名が対象外の LAME タグ" {
    const h = Header.parse(&.{ 0xFF, 0xFB, 0xB0, 0x64 }).?;
    var f: [626]u8 = @splat(0);
    try std.testing.expectEqual(null, parse(&f, h));

    @memcpy(f[36..40], "Xing");
    f[43] = flag_frames; // frames だけ
    @memcpy(f[48..52], "GOGO");
    try std.testing.expectEqual(null, parse(&f, h).?.lame);
    @memcpy(f[48..52], "Lavc");
    f[48 + 21] = 0x24; // delay = 0x240 = 576
    f[48 + 22] = 0x04;
    f[48 + 23] = 0x38; // padding = 0x438 = 1080
    try std.testing.expectEqual(576, parse(&f, h).?.lame.?.delay);
    try std.testing.expectEqual(1080, parse(&f, h).?.lame.?.padding);
}
