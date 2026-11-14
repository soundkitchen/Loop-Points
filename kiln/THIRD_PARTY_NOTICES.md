# 外部から取り込んだもの

K!LN 本体は MIT ライセンス([`LICENSE`](LICENSE))。このファイルには、K!LN のソースに取り込んだ外部のコードや数表の出所・ライセンス・元の著作権表示を記録する。

取り込んでよいライセンスと記録の仕方は [`docs/draft.md`](docs/draft.md) §2.5 のとおり。

libvorbis と libogg(BSD-3-Clause)は、ビルドした wasm にも入る。BSD-3-Clause は、バイナリで配るときにも著作権表示と条件を配布物に付けるよう求めるので、wasm を配る側(Loop Points)は、下の表示を配布物に含める([`docs/draft.md`](docs/draft.md) §2.17)。

## 取り込んだもの

### minimp3

- 出所: https://github.com/lieff/minimp3(コミット `ea99364f61c14656440e8d77e9c233ccf3124633`)
- ライセンス: CC0-1.0(表示義務なし。出所の記録として書く)
- 取り込んだもの: MPEG-1 Layer III の規格(ISO/IEC 11172-3)の数表。ハフマン符号表(`tabs` / `tab32` / `tab33` / `tabindex` / `g_linbits`)と、合成窓の係数(`g_win` と `mp3d_synth_pair` の定数)。コードは取り込んでいない
- 取り込んだ先: `src/mp3/huffman.zig`(ハフマン符号表)、`src/mp3/synth.zig`(合成窓)。取り出し方と確かめたことは [`docs/mp3-decoder.md`](docs/mp3-decoder.md) §1

### libvorbis

- 出所: https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz(1.3.7。sha256 `b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b`)
- ライセンス: BSD-3-Clause
- 取り込んだもの: Vorbis のエンコーダーに要るソース。`lib/` の C のファイル 21 個(`analysis` `bitrate` `block` `codebook` `envelope` `floor0` `floor1` `info` `lookup` `lpc` `lsp` `mapping0` `mdct` `psy` `registry` `res0` `sharedbook` `smallft` `synthesis` `vorbisenc` `window`)、`lib/` のヘッダー、`lib/books/` と `lib/modes/`(符号表と設定)、`include/vorbis/` の `codec.h` と `vorbisenc.h`、`COPYING`、`AUTHORS`。どのファイルも変えていない。取り込んでいないのは、デコード用の `vorbisfile`、調整用のツール(`barkmel.c` `psytune.c` `tone.c`)、ビルドの定義、ドキュメント、テスト
- 取り込んだ先: `vendor/libvorbis/`(元と同じ配置)。使い方は [`docs/ogg.md`](docs/ogg.md) §8

```
Copyright (c) 2002-2020 Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### libogg

- 出所: https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz(1.3.6。sha256 `5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061`)
- ライセンス: BSD-3-Clause
- 取り込んだもの: libvorbis が使う、ビットの読み書き(`src/bitwise.c`)と型の定義(`include/ogg/ogg.h`、`include/ogg/os_types.h`)、`COPYING`、`AUTHORS`。どのファイルも変えていない。ページの組み立て(`src/framing.c`)は取り込んでいない(Ogg のページは K!LN が作る)。libogg がビルドのときに作る `ogg/config_types.h` は、K!LN が書いたもの(`src/c/include/ogg/config_types.h`)を使う
- 取り込んだ先: `vendor/libogg/`(元と同じ配置)

```
Copyright (c) 2002, Xiph.org Foundation

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<!--
書き方(取り込むたびに 1 節を足す):

### <名前>

- 出所: <URL>(取り込んだ版やコミット)
- ライセンス: <SPDX 識別子>
- 取り込んだもの: <数表やコードの範囲>
- 取り込んだ先: <ファイル>

```
<元の著作権表示と許諾表示。表示義務がない CC0 / パブリックドメインは省いてよい>
```
-->
