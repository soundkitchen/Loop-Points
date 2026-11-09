// SPDX-License-Identifier: MIT
//! テスト用の音声をテストから参照するためのモジュール(build.zig がテストにだけ import させる)。
//! 各ファイルの作り方は README.md と generate.py を参照。

/// Lyria と同じ構成(CBR 192kbps、Xing/LAME タグなし、C2PA の GEOB 付き)
pub const lyria_like = @embedFile("lyria-like.mp3");
/// LAME タグ付きの CBR 128kbps
pub const cbr128_lame = @embedFile("cbr128-lame.mp3");
/// LAME タグ付きの VBR
pub const vbr_lame = @embedFile("vbr-lame.mp3");
/// 48kbps モノラル 48kHz、タグなし
pub const mono48k_notag = @embedFile("mono48k-notag.mp3");

/// 16bit ステレオ 44.1kHz。data の前に LIST チャンク
pub const s16_stereo_wav = @embedFile("s16-stereo.wav");
/// 8bit モノラル 8kHz、奇数フレーム(data の後に詰め物)。data の後にもチャンク
pub const u8_mono_wav = @embedFile("u8-mono.wav");
/// 24bit ステレオ 48kHz
pub const s24_stereo_wav = @embedFile("s24-stereo.wav");
/// 32bit 浮動小数点ステレオ 44.1kHz(fact チャンク付き)
pub const f32_stereo_wav = @embedFile("f32-stereo.wav");
/// 64bit 浮動小数点モノラル 22.05kHz
pub const f64_mono_wav = @embedFile("f64-mono.wav");
/// WAVE_FORMAT_EXTENSIBLE、32bit 整数 3 チャンネル 48kHz
pub const s32_3ch_ext_wav = @embedFile("s32-3ch-ext.wav");
