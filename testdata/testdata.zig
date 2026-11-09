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
