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

/// `detect` の結果
pub const Detected = struct {
    format: Format,
    /// デコード結果のサンプルレート(ヘッダーに書かれた値。HE-AAC の m4a は SBR の後、Opus は常に 48000)。
    /// 読めなければ null。読めないのは、ヘッダーから決められないもの(aac の ADTS は HE-AAC かどうかが分からない。
    /// SBR があるか分からない m4a。Vorbis でも Opus でもない Ogg、Ogg FLAC)と、ヘッダーが入力に入っていないもの
    /// (WAV の `fmt `、m4a の moov)
    sample_rate: ?u32,
};

/// 入力のヘッダーから、形式とデコード結果のサンプルレートを読む。拡張子は見ない。
/// ヘッダーだけを読み、音声のデータはたどらないので、入力はファイルの先頭の一部でもよい。先頭の一部を渡して
/// 形式かレートが読めなかったときは、全体を渡すと読めることがある(大きな ID3v2 タグの後ろの MP3 や FLAC、
/// moov が後ろにある m4a、`fmt ` が後ろにある WAV)。
///
/// WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)で、FLAC は先頭(ID3v2 タグがあればその後)の `fLaC` か
/// Ogg FLAC の印で、Ogg は先頭の `OggS` で、m4a は先頭の `ftyp` ボックスで、aac は先頭(ID3v2 タグがあれば
/// その後)に ADTS のフレームが続くことで判定し、それ以外は MPEG オーディオのフレームを探す(先頭にゴミがある
/// MP3 も、MP3 の解析と同じく受け付ける)。どれでもなければ null。
/// kiln が扱えない種類(MPEG-2 の MP3、μ-law の WAV、連結した Ogg、ALAC 以外の MP4 など)もその形式を返し、
/// レートもヘッダーから読む(ブラウザはデコードできることがある)。詳しいエラーは各形式の解析で出す
pub fn detect(input: []const u8) ?Detected {
    if (input.len >= 12 and std.mem.eql(u8, input[8..12], "WAVE")) {
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RIFF") or std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) {
            return .{ .format = .wav, .sample_rate = wav.headerSampleRate(input) };
        }
    }
    if (flac.hasSignature(input)) return .{ .format = .flac, .sample_rate = flac.headerSampleRate(input) };
    if (ogg.hasSignature(input)) return .{ .format = .ogg, .sample_rate = ogg.headerSampleRate(input) };
    if (m4a.hasSignature(input)) return .{ .format = .m4a, .sample_rate = m4a.headerSampleRate(input) catch null };
    // ADTS は MP3 と同期ワードが似ている(レイヤーの欄で区別する)ので、MP3 より先に見る
    if (aac.hasSignature(input)) return .{ .format = .aac, .sample_rate = null };
    return .{ .format = .mp3, .sample_rate = mp3.headerSampleRate(input) orelse return null };
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

fn expectDetected(format: Format, sample_rate: ?u32, input: []const u8) !void {
    const d = detect(input) orelse return error.TestExpectedDetected;
    try std.testing.expectEqual(format, d.format);
    try std.testing.expectEqual(sample_rate, d.sample_rate);
}

test detect {
    try expectDetected(.mp3, 44100, testdata.lyria_like);
    try expectDetected(.mp3, 44100, testdata.cbr128_lame);
    try expectDetected(.wav, 44100, testdata.s16_stereo_wav);
    try expectDetected(.wav, 48000, testdata.s24_stereo_wav);
    try expectDetected(.flac, 44100, testdata.s16_stereo_flac);
    try expectDetected(.flac, 96000, testdata.s20_mono_flac);
    try expectDetected(.ogg, 48000, testdata.opus_stereo);
    try expectDetected(.ogg, 44100, testdata.vorbis_stereo);
    try expectDetected(.ogg, 22050, testdata.vorbis_mono22k);
    try expectDetected(.m4a, 44100, testdata.aac_lc_ffmpeg_m4a);
    try expectDetected(.m4a, 44100, testdata.alac_afconvert_m4a);
    // HE-AAC は SBR の後のレート
    try expectDetected(.m4a, 44100, testdata.aac_he_afconvert_m4a);
    // aac(ADTS)は、ヘッダーから HE-AAC かどうかが分からないので、レートは読まない
    try expectDetected(.aac, null, testdata.lc_ffmpeg_aac);
    try expectDetected(.aac, null, testdata.he_afconvert_aac);
    // MP3 は ADTS と見間違えない
    for ([_][]const u8{ testdata.lyria_like, testdata.vbr_lame }) |m| try expectDetected(.mp3, 44100, m);
    try expectDetected(.mp3, 48000, testdata.mono48k_notag);
    // 先頭にゴミがある MP3 も MP3(MP3 の解析と同じ)
    var junk: [16 + testdata.cbr128_lame.len]u8 = undefined;
    @memset(junk[0..16], 0);
    @memcpy(junk[16..], testdata.cbr128_lame);
    try expectDetected(.mp3, 44100, &junk);
    // 先頭が同期ワードでも、フレームが続かなければ MP3 ではない
    try std.testing.expectEqual(null, detect("\xFF\xFB\x90\x64abc"));
    try std.testing.expectEqual(null, detect(""));
    try std.testing.expectEqual(null, detect("RIFF\x00\x00\x00\x00AVI "));
}

test "detect: kiln が扱えない種類も、形式とヘッダーのレートを返す" {
    // RF64 と RIFX(ビッグエンディアン)。fmt がなければレートは null
    try expectDetected(.wav, null, "RF64\xFF\xFF\xFF\xFFWAVE");
    const fmt_le = "fmt \x10\x00\x00\x00" ++ "\x07\x00\x01\x00" ++ "\x40\x1F\x00\x00" ++ "\x40\x1F\x00\x00\x01\x00\x08\x00";
    // μ-law(タグ 7)、8kHz。data チャンクがなくても読める
    try expectDetected(.wav, 8000, "RIFF\x00\x00\x00\x00WAVE" ++ fmt_le);
    try expectDetected(.wav, 8000, "RF64\xFF\xFF\xFF\xFFWAVE" ++ "ds64\x04\x00\x00\x00abcd" ++ fmt_le);
    try expectDetected(.wav, 8000, "RIFX\x00\x00\x00\x00WAVE" ++ "fmt \x00\x00\x00\x10" ++ "\x00\x01\x00\x01" ++ "\x00\x00\x1F\x40" ++ "\x00\x00\x1F\x40\x00\x01\x00\x08");
    // 奇数長のチャンクの後の詰め物を飛ばす
    try expectDetected(.wav, 8000, "RIFF\x00\x00\x00\x00WAVE" ++ "LIST\x03\x00\x00\x00abc\x00" ++ fmt_le);
    // レートが 0、fmt が途中で切れている
    try expectDetected(.wav, null, "RIFF\x00\x00\x00\x00WAVE" ++ "fmt \x10\x00\x00\x00" ++ "\x01\x00\x01\x00" ++ "\x00\x00\x00\x00");
    try expectDetected(.wav, null, "RIFF\x00\x00\x00\x00WAVE" ++ "fmt \x10\x00\x00\x00" ++ "\x01\x00\x01\x00\x40\x1F");

    // 壊れた FLAC、Ogg FLAC も FLAC(詳しいエラーは解析で出す)
    try expectDetected(.flac, null, "fLaC");
    try expectDetected(.flac, null, "OggS" ++ @as([24]u8, @splat(0)) ++ "\x7FFLAC");
    // STREAMINFO の後ろが壊れていても、レートは読める
    try expectDetected(.flac, 44100, testdata.s16_stereo_flac[0..42] ++ "\x7F\xFF\xFF\xFF");

    // MPEG-2 Layer III(22.05kHz、64kbps、フレームは 208 バイト)と MPEG-2.5(11.025kHz、32kbps、208 バイト)
    var mpeg2: [208 * 2]u8 = @splat(0);
    for ([_]usize{ 0, 208 }) |at| @memcpy(mpeg2[at..][0..4], "\xFF\xF3\x80\xC4");
    try expectDetected(.mp3, 22050, &mpeg2);
    try std.testing.expectError(error.UnsupportedFormat, mp3.probe(&mpeg2));
    for ([_]usize{ 0, 208 }) |at| @memcpy(mpeg2[at..][0..4], "\xFF\xE3\x40\xC4");
    try expectDetected(.mp3, 11025, &mpeg2);
}

test "detect: 入力がファイルの先頭の一部でも読める" {
    // 音声のデータの途中で切れていても、ヘッダーが入っていれば読める
    try expectDetected(.wav, 44100, testdata.s16_stereo_wav[0..64]);
    try expectDetected(.flac, 44100, testdata.s16_stereo_flac[0..64]);
    try expectDetected(.ogg, 44100, testdata.vorbis_stereo[0..128]);
    try expectDetected(.ogg, 48000, testdata.opus_stereo[0..128]);
    try expectDetected(.mp3, 44100, testdata.cbr128_lame[0..2048]);
    // m4a は moov が入っていれば読める(afconvert は moov が前、ffmpeg は後ろ)
    try expectDetected(.m4a, 44100, testdata.aac_lc_afconvert_m4a[0..4088]);
    try expectDetected(.m4a, null, testdata.aac_lc_ffmpeg_m4a[0..4096]);
    try expectDetected(.m4a, 44100, testdata.aac_lc_ffmpeg_m4a);
    // ID3v2 タグが入力より長いと、形式も分からない(全体を渡せば読める)
    const tag = "ID3\x03\x00\x00\x00\x00\x02\x00" ++ @as([256]u8, @splat(0));
    try std.testing.expectEqual(null, detect(tag[0..100]));
    try expectDetected(.mp3, 44100, tag ++ testdata.cbr128_lame);
    try expectDetected(.flac, 44100, tag ++ testdata.s16_stereo_flac);
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
