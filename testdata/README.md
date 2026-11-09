# テスト用の音声

コアのテストが使う MP3 と WAV。テストからは `testdata.zig` 経由で `@embedFile` する。

## MP3

どれも 2 秒の合成音(チャンネルごとに周波数の違う正弦波のスイープに、小さなノイズを混ぜたもの)を lame でエンコードしたもの。

| ファイル | 構成 | 確かめたいこと |
|---|---|---|
| `lyria-like.mp3` | CBR 192kbps、44.1kHz、joint stereo、Xing/LAME タグなし。先頭に C2PA の `GEOB` を 1 つ持つ ID3v2.3(中身は仮のバイト列) | Lyria の出力と同じ構成での基本動作、C2PA を引き継がないこと |
| `cbr128-lame.mp3` | CBR 128kbps、44.1kHz、joint stereo、Info + LAME タグ付き | LAME タグ付きの入力(タイムラインの 0 が delay の後になる) |
| `vbr-lame.mp3` | VBR(`-V 4`)、44.1kHz、joint stereo、Xing + LAME タグ付き | VBR の出力(`Xing` タグと TOC) |
| `mono48k-notag.mp3` | CBR 48kbps、48kHz、モノラル、タグなし | Info フレームのビットレートの引き上げ、ビットリザーバが深いときの carrier |

## WAV

同じような合成音(0.25 秒)を、Python だけで形式やチャンクの並びを変えて書いたもの。

| ファイル | 構成 | 確かめたいこと |
|---|---|---|
| `s16-stereo.wav` | 16bit、44.1kHz、ステレオ。`data` の前に `LIST` チャンク | 基本動作、知らないチャンクを読み飛ばすこと |
| `u8-mono.wav` | 8bit 符号なし、8kHz、モノラル、2001 フレーム。`data` の後に詰め物と `id3 ` チャンク | 奇数バイトの `data` と詰め物、`data` の後のチャンク |
| `s24-stereo.wav` | 24bit、48kHz、ステレオ | 3 バイト詰めのサンプル |
| `f32-stereo.wav` | 32bit 浮動小数点、44.1kHz、ステレオ。`fmt ` は 18 バイト、`fact` チャンク付き | 浮動小数点 |
| `f64-mono.wav` | 64bit 浮動小数点、22.05kHz、モノラル。`fact` チャンク付き | 64bit 浮動小数点 |
| `s32-3ch-ext.wav` | WAVE_FORMAT_EXTENSIBLE、32bit 整数、48kHz、3 チャンネル | EXTENSIBLE の SubFormat |

## 作り直し方

```sh
python3 testdata/generate.py       # MP3 と WAV の両方(lame が PATH にあること)
python3 testdata/generate.py wav   # WAV だけ(外部のツールは不要)
```

lame のバージョンが変わると出力のバイト列も変わる。今のファイルは LAME 64bits version 4.0(Homebrew)で作った。作り直したら、ここのバージョンを更新し、テストの期待値(フレーム数など)を確かめること。
