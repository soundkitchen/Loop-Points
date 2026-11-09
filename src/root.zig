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

test {
    _ = pcm;
    _ = mp3;
}

test version {
    _ = try std.SemanticVersion.parse(version);
}
