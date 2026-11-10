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

/// 16bit ステレオ 44.1kHz。LPC、ブロック長 1152(10 フレーム)、Vorbis コメント付き
pub const s16_stereo_flac = @embedFile("s16-stereo.flac");
/// 8bit モノラル 8kHz。固定予測だけ、ブロック長 576(最後のフレームは短い)
pub const u8_mono_flac = @embedFile("u8-mono.flac");
/// 24bit ステレオ 48kHz
pub const s24_stereo_flac = @embedFile("s24-stereo.flac");
/// 20bit モノラル 96kHz
pub const s20_mono_flac = @embedFile("s20-mono.flac");
/// 32bit 整数 3 チャンネル 48kHz
pub const s32_3ch_flac = @embedFile("s32-3ch.flac");

/// Opus ステレオ(opusenc、元は 44.1kHz、32kbps、0.5 秒)。pre-skip 312
pub const opus_stereo = @embedFile("opus-stereo.opus");
/// Opus モノラル(ffmpeg の libopus、48kHz、24kbps、0.5 秒)
pub const opus_mono_ffmpeg = @embedFile("opus-mono-ffmpeg.opus");
/// Vorbis ステレオ 44.1kHz(oggenc -q 0、0.5 秒)
pub const vorbis_stereo = @embedFile("vorbis-stereo.ogg");
/// Vorbis モノラル 22.05kHz(oggenc -q 2、0.5 秒)
pub const vorbis_mono22k = @embedFile("vorbis-mono22k.ogg");

/// AAC-LC ステレオ 44.1kHz(ffmpeg、0.5 秒)。先頭の遅延 1024 を編集リストに書く
pub const aac_lc_ffmpeg_m4a = @embedFile("aac-lc-ffmpeg.m4a");
/// AAC-LC ステレオ 44.1kHz(afconvert、0.5 秒)。遅延 2112 と長さを iTunSMPB に書く
pub const aac_lc_afconvert_m4a = @embedFile("aac-lc-afconvert.m4a");
/// HE-AAC ステレオ(afconvert、出力 44.1kHz、コア 22.05kHz、0.5 秒)
pub const aac_he_afconvert_m4a = @embedFile("aac-he-afconvert.m4a");
/// HE-AAC v2(afconvert、出力 44.1kHz ステレオ、コア 22.05kHz モノラル、0.5 秒)
pub const aac_hev2_afconvert_m4a = @embedFile("aac-hev2-afconvert.m4a");
/// ALAC 16bit ステレオ 44.1kHz(afconvert、0.25 秒)
pub const alac_afconvert_m4a = @embedFile("alac-afconvert.m4a");

/// ADTS の AAC-LC ステレオ 44.1kHz(ffmpeg、0.5 秒)
pub const lc_ffmpeg_aac = @embedFile("lc-ffmpeg.aac");
/// ADTS の AAC-LC ステレオ 44.1kHz(afconvert、0.5 秒)
pub const lc_afconvert_aac = @embedFile("lc-afconvert.aac");
/// ADTS の HE-AAC(afconvert)。ヘッダは 22.05kHz の AAC-LC に見える
pub const he_afconvert_aac = @embedFile("he-afconvert.aac");
