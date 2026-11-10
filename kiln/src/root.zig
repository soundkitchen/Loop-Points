// SPDX-License-Identifier: MIT
//! K!LN のコア。I/O を持たず、アロケータとバイト列/サンプル列、
//! `std.Io.Reader` / `std.Io.Writer` だけを扱う(docs/architecture.md)。
const std = @import("std");
const build_options = @import("build_options");

/// ライブラリのバージョン(build.zig.zon の `.version`)
pub const version: []const u8 = build_options.version;

/// PCM のサンプル形式と変換
pub const pcm = @import("pcm.zig");

/// MP3 の解析と無劣化トリム
pub const mp3 = @import("mp3.zig");

/// WAV の解析とサンプル精度のトリム
pub const wav = @import("wav.zig");

/// FLAC の解析と復号
pub const flac = @import("flac.zig");

/// Ogg(Vorbis / Opus)の解析
pub const ogg = @import("ogg.zig");

/// m4a(MP4 コンテナの AAC / ALAC)の解析
pub const m4a = @import("m4a.zig");

/// aac(ADTS)の解析
pub const aac = @import("aac.zig");

/// 扱える入力の形式
pub const Format = enum {
    mp3,
    wav,
    flac,
    ogg,
    m4a,
    aac,

    /// 形式の名前(`--format` の値などに使う)
    pub fn name(f: Format) []const u8 {
        return @tagName(f);
    }
};

/// 入力の形式を判定する。拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)で、
/// FLAC は先頭(ID3v2 タグがあればその後)の `fLaC` か Ogg FLAC の印で、Ogg は先頭の `OggS` で、
/// m4a は先頭の `ftyp` ボックスで、aac は先頭(ID3v2 タグがあればその後)に ADTS のフレームが続くことで判定し、
/// それ以外は MP3 の解析に任せる(先頭にゴミがある MP3 も、MP3 の解析と同じく受け付ける)。
/// 扱えない種類(MPEG-2 の MP3、Ogg FLAC、Speex、ALAC 以外の MP4 など)もその形式を返し、詳しいエラーは解析で出す
pub fn detect(input: []const u8) ?Format {
    if (input.len >= 12 and std.mem.eql(u8, input[8..12], "WAVE")) {
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RIFF") or std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) return .wav;
    }
    if (flac.hasSignature(input)) return .flac;
    if (ogg.hasSignature(input)) return .ogg;
    if (m4a.hasSignature(input)) return .m4a;
    // ADTS は MP3 と同期ワードが似ている(レイヤーの欄で区別する)ので、MP3 の解析より先に見る
    if (aac.hasSignature(input)) return .aac;
    _ = mp3.probe(input) catch |err| switch (err) {
        error.NotMp3 => return null,
        error.UnsupportedFormat => return .mp3,
    };
    return .mp3;
}

test {
    _ = pcm;
    _ = mp3;
    _ = wav;
    _ = flac;
    _ = ogg;
    _ = m4a;
    _ = aac;
}

test version {
    _ = try std.SemanticVersion.parse(version);
}

const testdata = @import("testdata");

test detect {
    try std.testing.expectEqual(Format.mp3, detect(testdata.lyria_like).?);
    try std.testing.expectEqual(Format.mp3, detect(testdata.cbr128_lame).?);
    try std.testing.expectEqual(Format.wav, detect(testdata.s16_stereo_wav).?);
    try std.testing.expectEqual(Format.wav, detect("RF64\xFF\xFF\xFF\xFFWAVE").?);
    try std.testing.expectEqual(null, detect("RIFF\x00\x00\x00\x00AVI "));
    try std.testing.expectEqual(Format.flac, detect(testdata.s16_stereo_flac).?);
    // 壊れた FLAC、Ogg FLAC も FLAC(詳しいエラーは解析で出す)
    try std.testing.expectEqual(Format.flac, detect("fLaC").?);
    try std.testing.expectEqual(Format.flac, detect("OggS" ++ @as([24]u8, @splat(0)) ++ "\x7FFLAC").?);
    try std.testing.expectEqual(Format.ogg, detect(testdata.opus_stereo).?);
    try std.testing.expectEqual(Format.ogg, detect(testdata.vorbis_stereo).?);
    try std.testing.expectEqual(Format.m4a, detect(testdata.aac_lc_ffmpeg_m4a).?);
    try std.testing.expectEqual(Format.m4a, detect(testdata.alac_afconvert_m4a).?);
    try std.testing.expectEqual(Format.aac, detect(testdata.lc_ffmpeg_aac).?);
    try std.testing.expectEqual(Format.aac, detect(testdata.he_afconvert_aac).?);
    // MP3 は ADTS と見間違えない
    for ([_][]const u8{ testdata.lyria_like, testdata.vbr_lame, testdata.mono48k_notag }) |m| try std.testing.expectEqual(Format.mp3, detect(m).?);
    // 先頭にゴミがある MP3 も MP3(MP3 の解析と同じ)
    var junk: [16 + testdata.cbr128_lame.len]u8 = undefined;
    @memset(junk[0..16], 0);
    @memcpy(junk[16..], testdata.cbr128_lame);
    try std.testing.expectEqual(Format.mp3, detect(&junk).?);
    // 先頭が同期ワードでも、フレームが続かなければ MP3 ではない
    try std.testing.expectEqual(null, detect("\xFF\xFB\x90\x64abc"));
    try std.testing.expectEqual(null, detect(""));
}

test "Ogg / m4a / aac の probe は、壊れた入力でも止まらない" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6b696c6e);
    const r = prng.random();
    const files = [_][]const u8{
        testdata.opus_stereo,          testdata.opus_mono_ffmpeg,       testdata.vorbis_stereo,
        testdata.vorbis_mono22k,       testdata.aac_lc_ffmpeg_m4a,      testdata.aac_lc_afconvert_m4a,
        testdata.aac_he_afconvert_m4a, testdata.aac_hev2_afconvert_m4a, testdata.alac_afconvert_m4a,
        testdata.lc_ffmpeg_aac,        testdata.he_afconvert_aac,
    };
    for (files) |src| {
        const buf = try gpa.alloc(u8, src.len);
        defer gpa.free(buf);
        for (0..200) |_| {
            @memcpy(buf, src);
            // 数バイトを書き換え、ときどき途中で切る
            for (0..r.intRangeAtMost(usize, 1, 8)) |_| buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
            const len = if (r.boolean()) buf.len else r.uintLessThan(usize, buf.len);
            const in = buf[0..len];
            _ = detect(in);
            _ = ogg.probe(in) catch {};
            _ = m4a.probe(in) catch {};
            _ = aac.probe(in) catch {};
        }
    }
}
