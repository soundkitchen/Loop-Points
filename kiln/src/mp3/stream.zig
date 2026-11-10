// SPDX-License-Identifier: MIT
//! 入力 MP3 の解析。ID3v2 タグを読み飛ばし、Xing / LAME ヘッダを読み、音声フレームの範囲と
//! タイムライン(再生したときのサンプル位置)を求める。
const std = @import("std");
const frame = @import("frame.zig");
const id3 = @import("id3.zig");
const xing = @import("xing.zig");
const Header = frame.Header;
const spf = frame.samples_per_frame;

/// MP3 デコーダの遅延(サンプル数)。ffmpeg は LAME タグの delay にこれを足して先頭を落とす
pub const decoder_delay = 529;

pub const Error = error{
    /// MPEG オーディオのフレームが見つからない
    NotMp3,
    /// MPEG オーディオだが、MPEG-1 Layer III ではない(MPEG-2 / 2.5、Layer I / II)
    UnsupportedFormat,
};

pub const Stream = struct {
    data: []const u8,
    /// 最初の音声フレームの位置(Xing / Info / VBRI のフレームは含めない)
    first_offset: usize,
    /// 最後の音声フレームの終わりの位置
    end_offset: usize,
    /// 音声フレームの数
    frames: u64,
    /// 最初の音声フレームのヘッダ
    header: Header,
    /// タイムラインの 0 に当たる、デコーダ出力上の位置。LAME タグがあれば delay + 529、なければ 0
    skip: u64,
    /// タイムラインの長さ(サンプル数)
    samples: u64,

    /// 入力全体を解析する。音声フレームは、最初のフレームから連続している分だけを使う
    /// (途中でフレームが途切れたり、サンプルレートやチャンネル数が変わったりしたら、そこで終わりとみなす。
    /// 末尾の ID3v1 / APE タグなどもここで除かれる)
    pub fn parse(data: []const u8) Error!Stream {
        var pos = try findFirstFrame(data, id3.skipTags(data));

        const first_header = Header.parse(data[pos..]).?;
        const tag = xing.parse(data[pos..][0..first_header.frameLen()], first_header);
        if (tag != null) pos += first_header.frameLen();

        var it: frame.Iterator = .{ .data = data, .pos = pos };
        var frames: u64 = 0;
        var header = first_header;
        while (it.next()) |f| {
            if (!f.header.compatible(first_header)) {
                it.pos = f.offset;
                break;
            }
            if (frames == 0) header = f.header;
            frames += 1;
        }

        const total = frames * spf;
        var skip: u64 = 0;
        var end = total;
        if (tag) |t| if (t.lame) |lame| {
            skip = @as(u64, lame.delay) + decoder_delay;
            // ffmpeg は [frames * spf - padding + 529, frames * spf) を落とす。padding が 529 未満なら何も落とさない
            end = total -| (@as(u64, lame.padding) -| decoder_delay);
        };

        return .{
            .data = data,
            .first_offset = pos,
            .end_offset = it.pos,
            .frames = frames,
            .header = header,
            .skip = skip,
            .samples = end -| skip,
        };
    }

    /// 音声フレームを先頭からたどるイテレータ
    pub fn iterator(s: Stream) frame.Iterator {
        return .{ .data = s.data[0..s.end_offset], .pos = s.first_offset };
    }
};

/// `start` 以降で最初のフレームの位置。誤検出を避けるため、直後にもう 1 つ同じ形式の
/// フレームが続くこと(またはフレームが入力の終わりまでぴったり収まること)を確かめる。
/// 先に MPEG-1 Layer III 以外の MPEG オーディオのフレームが見つかったら `UnsupportedFormat`
fn findFirstFrame(data: []const u8, start: usize) Error!usize {
    var pos = start;
    while (pos + 4 <= data.len) : (pos += 1) {
        if (!syncCandidate(data[pos..])) continue;
        if (Header.parse(data[pos..])) |h| {
            const next = pos + h.frameLen();
            if (next == data.len) return pos;
            if (next < data.len and syncCandidate(data[next..])) {
                if (Header.parse(data[next..])) |h2| if (h2.compatible(h)) return pos;
            }
            continue;
        }
        const any = frame.AnyHeader.parse(data[pos..]) orelse continue;
        const next = pos + any.len;
        if (next > data.len) continue;
        if (next == data.len) return error.UnsupportedFormat;
        if (!syncCandidate(data[next..])) continue;
        const any2 = frame.AnyHeader.parse(data[next..]) orelse continue;
        if (any2.kind == any.kind) return error.UnsupportedFormat;
    }
    return error.NotMp3;
}

/// 最初のフレームの候補にしてよいか。emphasis の予約値(2)のヘッダは、ゴミが偶然同期ワードに
/// 見えたものとみなして候補にしない(同期の判定を厳しく保つため)。見つかった後のフレームでは
/// emphasis を見ない(`Header.parse`。ffmpeg と同じく予約値のフレームもデコードする)
fn syncCandidate(bytes: []const u8) bool {
    return bytes.len >= 4 and bytes[3] & 3 != 2;
}

const testdata = @import("testdata");

test "parse: Lyria と同じ構成(タグなし)" {
    const s = try Stream.parse(testdata.lyria_like);
    try std.testing.expectEqual(78, s.frames);
    try std.testing.expectEqual(0, s.skip);
    try std.testing.expectEqual(78 * spf, s.samples);
    try std.testing.expectEqual(44100, s.header.sampleRate());
    try std.testing.expectEqual(testdata.lyria_like.len, s.end_offset);
}

test "parse: LAME タグ付き" {
    // lame の delay 576 / padding 1080。ffmpeg のデコード結果も 88200 サンプル
    for ([_][]const u8{ testdata.cbr128_lame, testdata.vbr_lame }) |data| {
        const s = try Stream.parse(data);
        try std.testing.expectEqual(78, s.frames);
        try std.testing.expectEqual(576 + 529, s.skip);
        try std.testing.expectEqual(88200, s.samples);
    }
}

test "parse: 末尾のゴミと、フレームのない入力" {
    var buf: [testdata.lyria_like.len + 128]u8 = undefined;
    @memcpy(buf[0..testdata.lyria_like.len], testdata.lyria_like);
    @memcpy(buf[testdata.lyria_like.len..][0..3], "TAG"); // ID3v1
    @memset(buf[testdata.lyria_like.len + 3 ..], 0);
    const s = try Stream.parse(&buf);
    try std.testing.expectEqual(78, s.frames);
    try std.testing.expectEqual(testdata.lyria_like.len, s.end_offset);

    try std.testing.expectError(error.NotMp3, Stream.parse("RIFF\x00\x00\x00\x00WAVEfmt "));
    try std.testing.expectError(error.NotMp3, Stream.parse(""));
}

test "parse: MPEG-1 Layer III 以外の MPEG オーディオは UnsupportedFormat" {
    // MPEG-2 Layer III 80kbps 22.05kHz のフレーム(261 バイト)を 2 つ。ID3v2 タグの後に
    // ゼロ埋めがあっても、MP3 ではない(NotMp3)ではなく対応していない形式と報告する
    const mpeg2 = "\xFF\xF3\x90\x64" ++ @as([257]u8, @splat(0));
    const id3_tag = "ID3\x03\x00\x00\x00\x00\x00\x00";
    try std.testing.expectError(error.UnsupportedFormat, Stream.parse(mpeg2 ++ mpeg2));
    try std.testing.expectError(error.UnsupportedFormat, Stream.parse(id3_tag ++ @as([16]u8, @splat(0)) ++ mpeg2 ++ mpeg2));
    // フレームが入力の終わりにぴったり収まる 1 つだけの場合も同じ
    try std.testing.expectError(error.UnsupportedFormat, Stream.parse(mpeg2));
    // フレームの長さが合わない同期ワードだけなら MP3 ではない
    try std.testing.expectError(error.NotMp3, Stream.parse("\xFF\xF3\x90\x64" ++ @as([200]u8, @splat(0))));
}
