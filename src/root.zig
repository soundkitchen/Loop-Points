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

/// 扱える入力の形式
pub const Format = enum {
    mp3,
    wav,

    /// 形式の名前(`--format` の値などに使う)
    pub fn name(f: Format) []const u8 {
        return @tagName(f);
    }
};

/// 入力の形式を判定する。拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)で判定し、
/// それ以外は MP3 の解析に任せる(先頭にゴミがある MP3 も、MP3 の解析と同じく受け付ける)。
/// MPEG オーディオだが扱えない形式(MPEG-2 など)も `.mp3` を返し、詳しいエラーは解析で出す
pub fn detect(input: []const u8) ?Format {
    if (input.len >= 12 and std.mem.eql(u8, input[8..12], "WAVE")) {
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RIFF") or std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) return .wav;
    }
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
    try std.testing.expectEqual(null, detect("fLaC"));
    // 先頭にゴミがある MP3 も MP3(MP3 の解析と同じ)
    var junk: [16 + testdata.cbr128_lame.len]u8 = undefined;
    @memset(junk[0..16], 0);
    @memcpy(junk[16..], testdata.cbr128_lame);
    try std.testing.expectEqual(Format.mp3, detect(&junk).?);
    // 先頭が同期ワードでも、フレームが続かなければ MP3 ではない
    try std.testing.expectEqual(null, detect("\xFF\xFB\x90\x64abc"));
    try std.testing.expectEqual(null, detect(""));
}
