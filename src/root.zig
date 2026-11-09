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

/// 先頭のバイト列(マジックバイト)から形式を判定する。拡張子は見ない。
/// 判定できるのは入口だけで、中身が正しいかは各形式の解析で確かめる
pub fn detect(input: []const u8) ?Format {
    if (input.len >= 12 and std.mem.eql(u8, input[8..12], "WAVE")) {
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RIFF") or std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) return .wav;
    }
    // ID3v2 タグか、MPEG オーディオのフレーム同期(先頭 11 ビットがすべて 1)
    if (std.mem.startsWith(u8, input, "ID3")) return .mp3;
    if (input.len >= 2 and input[0] == 0xFF and input[1] & 0xE0 == 0xE0) return .mp3;
    return null;
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
    try std.testing.expectEqual(null, detect(""));
}
