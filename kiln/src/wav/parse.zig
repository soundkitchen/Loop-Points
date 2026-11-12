// SPDX-License-Identifier: MIT
//! WAV(RIFF / WAVE)の解析。`fmt ` と `data` のチャンクを探し、サンプル形式と PCM の範囲を求める。
const std = @import("std");
const pcm = @import("../pcm.zig");

pub const Error = error{
    /// RIFF / WAVE のヘッダがない
    NotWav,
    /// WAV だが扱えない形式(RF64、ビッグエンディアンの RIFX、PCM / 浮動小数点以外の符号化など)
    UnsupportedFormat,
    /// `fmt ` / `data` のチャンクがない、または `fmt ` の値が壊れている
    InvalidWav,
};

/// WAVE_FORMAT_PCM / WAVE_FORMAT_IEEE_FLOAT / WAVE_FORMAT_EXTENSIBLE
const tag_pcm = 1;
const tag_float = 3;
const tag_extensible = 0xFFFE;

pub const Wav = struct {
    sample_rate: u32,
    channels: u16,
    format: pcm.Format,
    /// `fmt ` チャンクの中身(チャンクヘッダを除く)。トリムではそのまま書き戻す
    fmt_chunk: []const u8,
    /// PCM(`data` チャンクの中身)。1 フレーム(全チャンネルの 1 サンプルずつ)の倍数の長さに切り詰めてある
    data: []const u8,

    /// 1 フレームのバイト数
    pub fn frameLen(w: Wav) usize {
        return @as(usize, w.channels) * w.format.bytes();
    }

    /// フレーム数(チャンネルあたりのサンプル数)
    pub fn frames(w: Wav) u64 {
        return w.data.len / w.frameLen();
    }

    pub fn parse(input: []const u8) Error!Wav {
        if (input.len < 12) return error.NotWav;
        const riff = input[0..4];
        if (std.mem.eql(u8, riff, "RF64") or std.mem.eql(u8, riff, "RIFX")) {
            if (std.mem.eql(u8, input[8..12], "WAVE")) return error.UnsupportedFormat;
        }
        if (!std.mem.eql(u8, riff, "RIFF") or !std.mem.eql(u8, input[8..12], "WAVE")) return error.NotWav;

        var fmt_chunk: ?[]const u8 = null;
        var data: ?[]const u8 = null;
        var pos: usize = 12;
        // pos は飽和加算で進めるので入力の長さを超えることがある。usize が 32bit の wasm でも
        // pos + 8 があふれないよう、引き算で比べる
        while (pos <= input.len and input.len - pos >= 8) {
            const id = input[pos..][0..4];
            const size = std.mem.readInt(u32, input[pos + 4 ..][0..4], .little);
            const body_start = pos + 8;
            // 長さが入力を超える(書き込み途中のファイルや、長さを 0xFFFFFFFF にしたストリーミング出力)
            // ときは、入力の終わりまでとみなす
            const body = input[body_start..][0..@min(size, input.len - body_start)];
            if (std.mem.eql(u8, id, "fmt ")) {
                fmt_chunk = body;
            } else if (std.mem.eql(u8, id, "data")) {
                if (data == null) data = body;
            }
            pos = body_start +| size;
            pos +|= size & 1; // 奇数長のチャンクの後には詰め物が 1 バイトある
        }

        const f = fmt_chunk orelse return error.InvalidWav;
        const d = data orelse return error.InvalidWav;
        if (f.len < 16) return error.InvalidWav;
        var tag = std.mem.readInt(u16, f[0..2], .little);
        const channels = std.mem.readInt(u16, f[2..4], .little);
        const sample_rate = std.mem.readInt(u32, f[4..8], .little);
        const block_align = std.mem.readInt(u16, f[12..14], .little);
        const bits = std.mem.readInt(u16, f[14..16], .little);
        if (tag == tag_extensible) {
            if (f.len < 40) return error.InvalidWav;
            // SubFormat の GUID の先頭 2 バイトが、実際の符号化のタグ
            tag = std.mem.readInt(u16, f[24..26], .little);
        }
        if (channels == 0 or sample_rate == 0) return error.InvalidWav;

        const format: pcm.Format = switch (tag) {
            tag_pcm => switch (bits) {
                8 => .u8,
                16 => .i16,
                24 => .i24,
                32 => .i32,
                else => return error.UnsupportedFormat,
            },
            tag_float => switch (bits) {
                32 => .f32,
                64 => .f64,
                else => return error.UnsupportedFormat,
            },
            else => return error.UnsupportedFormat,
        };
        const frame_len = @as(usize, channels) * format.bytes();
        if (block_align != frame_len) return error.InvalidWav;

        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .format = format,
            .fmt_chunk = f,
            .data = d[0 .. d.len - d.len % frame_len],
        };
    }
};

/// `fmt ` チャンクに書かれたサンプルレート。符号化の種類は見ないので、kiln が扱わない WAV(RF64、ビッグエンディアンの
/// RIFX、μ-law など)でも読む。`data` チャンクは要らないので、入力がファイルの先頭の一部でもよい。
/// WAV でない、`fmt ` が入力に入っていない、レートが 0 のときは null
pub fn headerSampleRate(input: []const u8) ?u32 {
    if (input.len < 12 or !std.mem.eql(u8, input[8..12], "WAVE")) return null;
    const riff = input[0..4];
    const big = std.mem.eql(u8, riff, "RIFX");
    if (!big and !std.mem.eql(u8, riff, "RIFF") and !std.mem.eql(u8, riff, "RF64")) return null;

    var pos: usize = 12;
    while (pos <= input.len and input.len - pos >= 8) {
        const size = readU32(input[pos + 4 ..][0..4], big);
        const body_start = pos + 8;
        if (std.mem.eql(u8, input[pos..][0..4], "fmt ")) {
            // タグ(2)、チャンネル数(2)、サンプルレート(4)
            if (size < 8 or input.len - body_start < 8) return null;
            const rate = readU32(input[body_start + 4 ..][0..4], big);
            return if (rate == 0) null else rate;
        }
        pos = body_start +| size;
        pos +|= size & 1;
    }
    return null;
}

fn readU32(b: *const [4]u8, big: bool) u32 {
    return std.mem.readInt(u32, b, if (big) .big else .little);
}

const testdata = @import("testdata");

test "parse: testdata の WAV" {
    const T = struct { []const u8, u32, u16, pcm.Format, u64 };
    for ([_]T{
        .{ testdata.s16_stereo_wav, 44100, 2, .i16, 11025 },
        .{ testdata.u8_mono_wav, 8000, 1, .u8, 2001 },
        .{ testdata.s24_stereo_wav, 48000, 2, .i24, 12000 },
        .{ testdata.f32_stereo_wav, 44100, 2, .f32, 11025 },
        .{ testdata.f64_mono_wav, 22050, 1, .f64, 5512 },
        .{ testdata.s32_3ch_ext_wav, 48000, 3, .i32, 12000 },
    }) |c| {
        const w = try Wav.parse(c[0]);
        try std.testing.expectEqual(c[1], w.sample_rate);
        try std.testing.expectEqual(c[2], w.channels);
        try std.testing.expectEqual(c[3], w.format);
        try std.testing.expectEqual(c[4], w.frames());
    }
}

test "parse: 長さが入力を超える data(ストリーミング出力)は入力の終わりまで" {
    var buf: [testdata.s16_stereo_wav.len]u8 = testdata.s16_stereo_wav.*;
    const w0 = try Wav.parse(&buf);
    const data_size_pos = @intFromPtr(w0.data.ptr) - @intFromPtr(&buf) - 4;
    std.mem.writeInt(u32, buf[data_size_pos..][0..4], 0xFFFFFFFF, .little);
    std.mem.writeInt(u32, buf[4..8], 0xFFFFFFFF, .little);
    // 途中で切れた入力でも、フレームの区切りまでは読める
    const w = try Wav.parse(buf[0 .. buf.len - 3]);
    try std.testing.expectEqual(11025 - 1, w.frames());
}

test "parse: 扱えない入力" {
    const t = std.testing;
    try t.expectError(error.NotWav, Wav.parse(""));
    try t.expectError(error.NotWav, Wav.parse("ID3\x03\x00\x00\x00\x00\x00\x00\xFF\xFB"));
    try t.expectError(error.UnsupportedFormat, Wav.parse("RF64\xFF\xFF\xFF\xFFWAVEds64"));
    try t.expectError(error.InvalidWav, Wav.parse("RIFF\x04\x00\x00\x00WAVE"));
    // ADPCM(タグ 2)
    var adpcm: [testdata.s16_stereo_wav.len]u8 = testdata.s16_stereo_wav.*;
    std.mem.writeInt(u16, adpcm[20..22], 2, .little);
    try t.expectError(error.UnsupportedFormat, Wav.parse(&adpcm));
    // block_align がサンプル形式と合わない
    var bad: [testdata.s16_stereo_wav.len]u8 = testdata.s16_stereo_wav.*;
    std.mem.writeInt(u16, bad[32..34], 3, .little);
    try t.expectError(error.InvalidWav, Wav.parse(&bad));
}
