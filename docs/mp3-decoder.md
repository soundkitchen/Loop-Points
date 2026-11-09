# MP3 デコーダ

MPEG-1 Layer III のデコーダ(`src/mp3/` の `bits` / `huffman` ほか)の設計と検証の記録。MP3 → WAV の書き出しに使う。扱う範囲は無劣化トリム(`docs/lyria-mp3.md` §5.1)と同じく MPEG-1 Layer III だけ。

## 1. 数表の出所

規格(ISO/IEC 11172-3)が定める数表のうち、計算で導けないものは [minimp3](https://github.com/lieff/minimp3)(CC0 1.0、パブリックドメイン相当)から取った。K!LN のライセンスを MIT に近いものにするため、LGPL の ffmpeg の表は使わない。

| 表 | 取り方 | 確かめたこと |
|---|---|---|
| ハフマン符号表(big_values 用の 15 表 + linbits、count1 の表 A / B) | minimp3 の `tabs` / `tab32` / `tab33` / `tabindex` / `g_linbits` を、先読みで引ける木の形のまま使う(形式は `src/mp3/huffman.zig` の冒頭) | どの表も符号が完全(Kraft の和が 1)で、(x, y) がすべて 1 回ずつ現れる。表 1 の全符号と、表 13 / 15 / 16 / 24 の (0,0) の符号が規格書と一致する(テスト) |

表はスクリプトで minimp3 のソースから抜き出して Zig のソースに書き出した(手で写していない)。
