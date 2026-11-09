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

/// 扱える入力の形式
pub const Format = enum {
    mp3,
    wav,
    flac,

    /// 形式の名前(`--format` の値などに使う)
    pub fn name(f: Format) []const u8 {
        return @tagName(f);
    }
};

/// 入力の形式を判定する。拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)で、
/// FLAC は先頭(ID3v2 タグがあればその後)の `fLaC` か Ogg FLAC の印で判定し、
/// それ以外は MP3 の解析に任せる(先頭にゴミがある MP3 も、MP3 の解析と同じく受け付ける)。
/// 扱えない種類(MPEG-2 の MP3、Ogg FLAC など)もその形式を返し、詳しいエラーは解析で出す
pub fn detect(input: []const u8) ?Format {
    if (input.len >= 12 and std.mem.eql(u8, input[8..12], "WAVE")) {
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RIFF") or std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) return .wav;
    }
    if (flac.hasSignature(input)) return .flac;
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
    // 先頭にゴミがある MP3 も MP3(MP3 の解析と同じ)
    var junk: [16 + testdata.cbr128_lame.len]u8 = undefined;
    @memset(junk[0..16], 0);
    @memcpy(junk[16..], testdata.cbr128_lame);
    try std.testing.expectEqual(Format.mp3, detect(&junk).?);
    // 先頭が同期ワードでも、フレームが続かなければ MP3 ではない
    try std.testing.expectEqual(null, detect("\xFF\xFB\x90\x64abc"));
    try std.testing.expectEqual(null, detect(""));
}
