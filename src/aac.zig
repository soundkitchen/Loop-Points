// SPDX-License-Identifier: MIT
//! aac(ADTS のフレームを並べた AAC)の解析(設計は docs/aac.md)。
//!
//! フレームのヘッダだけを読む。音声データは読まないので、HE-AAC(SBR / PS)かどうかは分からない
//! (ADTS のヘッダには書けない。HE-AAC ならデコード結果のレートはヘッダの 2 倍、v2 なら 2 チャンネル)。
const std = @import("std");
const id3 = @import("mp3/id3.zig");

pub const ParseError = error{
    /// 先頭(ID3v2 タグがあればその後)が ADTS のフレームではない
    NotAac,
    /// チャンネル構成が 0(プログラム設定が音声データの中にある)など
    UnsupportedFormat,
};

pub const rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

/// ADTS のヘッダに書けるプロファイル(オブジェクトタイプ 1〜4)
pub const Profile = enum(u2) { main, lc, ssr, ltp };

pub const Info = struct {
    profile: Profile,
    /// ヘッダの MPEG の版(2 か 4)
    mpeg_version: u8,
    /// ヘッダのサンプルレート(HE-AAC ならデコード結果はこの 2 倍)
    sample_rate: u32,
    /// ヘッダのチャンネル数(HE-AAC v2 ならデコード結果は 2)
    channels: u8,
    /// フレームの数
    frames: u64,
    /// 長さ(ヘッダのサンプルレートのサンプル数。フレームあたり 1024)。先頭の遅延も含む
    samples: u64,
};

const Header = struct {
    mpeg_version: u8,
    profile: Profile,
    rate_index: u4,
    channel_config: u3,
    /// ヘッダを含むフレームの長さ
    len: u13,
    /// フレームに入っている raw_data_block の数(1〜4)
    blocks: u3,

    fn parse(d: []const u8) ?Header {
        if (d.len < 7 or d[0] != 0xFF or d[1] & 0xF6 != 0xF0) return null;
        const h: Header = .{
            .mpeg_version = if (d[1] & 0x08 != 0) 2 else 4,
            .profile = @fromBackingInt(@intCast(d[2] >> 6)),
            .rate_index = @truncate(d[2] >> 2),
            .channel_config = @truncate((d[2] & 1) << 2 | d[3] >> 6),
            .len = @truncate(@as(u16, d[3] & 3) << 11 | @as(u16, d[4]) << 3 | d[5] >> 5),
            .blocks = @as(u3, @truncate(d[6] & 3)) + 1,
        };
        const header_len: u13 = if (d[1] & 1 == 0) 9 else 7;
        if (h.rate_index >= rates.len or h.len < header_len) return null;
        return h;
    }

    /// 同じストリームのフレームか(版・プロファイル・レート・チャンネル構成が同じ)
    fn sameStream(a: Header, b: Header) bool {
        return a.mpeg_version == b.mpeg_version and a.profile == b.profile and
            a.rate_index == b.rate_index and a.channel_config == b.channel_config;
    }
};

/// `pos` から始まる、`first` と同じストリームのフレーム。`lookahead` なら、次のフレームも続く
/// (か入力・タグが続く)ときだけ返す(最初のフレームと、ゴミの後で同期し直すときに偶然の一致を避ける)
fn frameAt(input: []const u8, pos: usize, first: ?Header, lookahead: bool) ?Header {
    const h = Header.parse(input[pos..]) orelse return null;
    if (first) |f| if (!f.sameStream(h)) return null;
    const end = pos + h.len;
    if (end > input.len) return null;
    if (end == input.len or !lookahead) return h;
    const next = Header.parse(input[end..]) orelse return if (isTag(input[end..])) h else null;
    return if (next.sameStream(h)) h else null;
}

/// 末尾に付くタグ(ID3v1、APEv2、ID3v2)
fn isTag(d: []const u8) bool {
    return std.mem.startsWith(u8, d, "TAG") or std.mem.startsWith(u8, d, "APETAGEX") or std.mem.startsWith(u8, d, "ID3");
}

/// 先頭(ID3v2 タグがあればその後)が ADTS のフレームで、次のフレームも続くか(`kiln.detect` に使う)
pub fn hasSignature(input: []const u8) bool {
    return frameAt(input, id3.skipTags(input), null, true) != null;
}

/// 入力全体を解析して、フレームの数と長さを返す。フレームの間のゴミは、同じストリームのフレームが
/// 続くところまで読み飛ばす。末尾のタグと、途切れた最後のフレームは数えない
pub fn probe(input: []const u8) ParseError!Info {
    var pos = id3.skipTags(input);
    const first = frameAt(input, pos, null, true) orelse return error.NotAac;
    if (first.channel_config == 0) return error.UnsupportedFormat;
    var frames: u64 = 0;
    var samples: u64 = 0;
    while (pos < input.len) {
        if (frameAt(input, pos, first, false)) |h| {
            frames += 1;
            samples += @as(u64, h.blocks) * 1024;
            pos += h.len;
            continue;
        }
        if (isTag(input[pos..])) break;
        // ゴミか途切れたフレーム: 次の同期ワードを探す
        pos += 1;
        while (pos < input.len and !(input[pos] == 0xFF and frameAt(input, pos, first, true) != null)) pos += 1;
    }
    return .{
        .profile = first.profile,
        .mpeg_version = first.mpeg_version,
        .sample_rate = rates[first.rate_index],
        .channels = if (first.channel_config == 7) 8 else first.channel_config,
        .frames = frames,
        .samples = samples,
    };
}

const testdata = @import("testdata");

test "probe: ffmpeg と afconvert の AAC-LC" {
    const f = try probe(testdata.lc_ffmpeg_aac);
    try std.testing.expectEqual(Profile.lc, f.profile);
    try std.testing.expectEqual(44100, f.sample_rate);
    try std.testing.expectEqual(2, f.channels);
    try std.testing.expectEqual(23, f.frames);
    try std.testing.expectEqual(23 * 1024, f.samples);
    const a = try probe(testdata.lc_afconvert_aac);
    try std.testing.expectEqual(24, a.frames);
}

test "probe: HE-AAC はヘッダでは AAC-LC に見える" {
    const h = try probe(testdata.he_afconvert_aac);
    try std.testing.expectEqual(Profile.lc, h.profile);
    try std.testing.expectEqual(22050, h.sample_rate);
    try std.testing.expectEqual(2, h.channels);
}

test "probe: ゴミと途切れたフレーム" {
    const gpa = std.testing.allocator;
    const src = testdata.lc_ffmpeg_aac;
    const base = try probe(src);
    // 先頭に ID3v2、途中にゴミ、末尾に ID3v1 と途切れたフレーム
    const tag = "ID3\x03\x00\x00\x00\x00\x00\x00";
    // ゴミは 2 つ目のフレームの後に入れる(最初のフレームは、次のフレームが続くことで見分ける)
    const first_len = Header.parse(src).?.len;
    const two = first_len + Header.parse(src[first_len..]).?.len;
    const id3v1 = "TAG" ++ @as([125]u8, @splat('x'));
    const buf = try std.mem.concat(gpa, u8, &.{ tag, src[0..two], "junk\xFF\xF1", src[two..], src[0..20], id3v1 });
    defer gpa.free(buf);
    try std.testing.expectEqual(base.frames, (try probe(buf)).frames);
    try std.testing.expect(hasSignature(buf));
    try std.testing.expectError(error.NotAac, probe("junk"));
    try std.testing.expectError(error.NotAac, probe(testdata.cbr128_lame));
    try std.testing.expect(!hasSignature(testdata.cbr128_lame));
}
