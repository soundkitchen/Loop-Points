//! ID3v2 タグの読み飛ばしと、`iTunSMPB` を入れた ID3v2.3 タグの書き出し。
const std = @import("std");
const Io = std.Io;

/// 先頭に続く ID3v2 タグをすべて読み飛ばし、その直後の位置を返す。
/// タグのサイズが壊れていて入力を超える場合は、入力の終わりを返す
pub fn skipTags(data: []const u8) usize {
    var pos: usize = 0;
    while (data.len - pos >= 10 and std.mem.eql(u8, data[pos..][0..3], "ID3")) {
        const h = data[pos..][0..10];
        const footer: usize = if (h[3] == 4 and h[5] & 0x10 != 0) 10 else 0;
        const size = 10 + footer + @as(usize, syncsafeDecode(h[6..10].*));
        if (data.len - pos < size) return data.len;
        pos += size;
    }
    return pos;
}

fn syncsafeDecode(b: [4]u8) u28 {
    var v: u28 = 0;
    for (b) |x| v = (v << 7) | (x & 0x7F);
    return v;
}

fn syncsafeEncode(v: u28) [4]u8 {
    return .{
        @intCast((v >> 21) & 0x7F),
        @intCast((v >> 14) & 0x7F),
        @intCast((v >> 7) & 0x7F),
        @intCast(v & 0x7F),
    };
}

/// `iTunSMPB` の値の長さ: 先頭の空白 + 3 フィールド(8 桁) + 有効サンプル数(16 桁) + 8 フィールド(8 桁)
const smpb_value_len = 9 * 3 + 17 + 9 * 8;
/// COMM フレームの中身: エンコーディング(1) + 言語(3) + 説明("iTunSMPB" + NUL) + 値
const comm_body_len = 1 + 3 + 9 + smpb_value_len;
/// タグ全体の長さ(タグヘッダ 10 + フレームヘッダ 10 + 中身)
pub const itunsmpb_tag_len = 10 + 10 + comm_body_len;

/// `COMM` フレーム(説明 `iTunSMPB`)を 1 つだけ持つ ID3v2.3 タグを書く。
/// priming / padding は LAME タグの delay / padding と同じ値、samples は有効なサンプル数(docs/lyria-mp3.md §5.3)
pub fn writeItunSmpbTag(w: *Io.Writer, priming: u32, padding: u32, samples: u64) Io.Writer.Error!void {
    // タグヘッダ: ID3v2.3.0、フラグなし、サイズは syncsafe
    try w.writeAll("ID3\x03\x00\x00");
    try w.writeAll(&syncsafeEncode(itunsmpb_tag_len - 10));
    // フレームヘッダ: v2.3 のフレームサイズは syncsafe ではない通常の 32bit 整数
    try w.writeAll("COMM");
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, comm_body_len, .big);
    try w.writeAll(&size);
    try w.writeAll("\x00\x00");
    // ISO-8859-1、言語 eng、説明 "iTunSMPB" + NUL
    try w.writeAll("\x00eng" ++ "iTunSMPB\x00");
    try w.print(" {X:0>8} {X:0>8} {X:0>8} {X:0>16}", .{ 0, priming, padding, samples });
    for (0..8) |_| try w.writeAll(" 00000000");
}

test skipTags {
    try std.testing.expectEqual(0, skipTags("\xFF\xFB\x90\x64"));
    // 中身 3 バイトのタグが 2 つ続く
    const two = "ID3\x03\x00\x00\x00\x00\x00\x03abc" ++ "ID3\x04\x00\x00\x00\x00\x00\x01x" ++ "\xFF\xFB";
    try std.testing.expectEqual(two.len - 2, skipTags(two));
    // ID3v2.4 のフッタ付き
    const footer = "ID3\x04\x00\x10\x00\x00\x00\x01x" ++ "3DI\x04\x00\x10\x00\x00\x00\x01" ++ "\xFF";
    try std.testing.expectEqual(footer.len - 1, skipTags(footer));
    // サイズが入力を超える
    try std.testing.expectEqual(12, skipTags("ID3\x03\x00\x00\x00\x00\x01\x00ab"));
}

test writeItunSmpbTag {
    var buf: [itunsmpb_tag_len]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeItunSmpbTag(&w, 0xB1C, 0x7F0, 441000);
    try std.testing.expectEqual(itunsmpb_tag_len, w.end);
    try std.testing.expectEqual(itunsmpb_tag_len, skipTags(&buf));
    try std.testing.expectEqualStrings(
        "ID3\x03\x00\x00\x00\x00\x01\x0B" ++ "COMM\x00\x00\x00\x81\x00\x00" ++ "\x00eng" ++ "iTunSMPB\x00" ++
            " 00000000 00000B1C 000007F0 000000000006BAA8" ++
            " 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000",
        &buf,
    );
}
