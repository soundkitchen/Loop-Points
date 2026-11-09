# テスト用の音声

コアのテストが使う MP3、WAV、FLAC。テストからは `testdata.zig` 経由で `@embedFile` する。

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

## FLAC

WAV と同じ合成音を、参照実装の flac でエンコードしたもの。シークテーブルは付けない(`--no-seektable`)。flac は Vorbis コメント(ベンダー文字列)と 8KiB の PADDING を付ける。

| ファイル | 構成 | 確かめたいこと |
|---|---|---|
| `s16-stereo.flac` | 16bit、44.1kHz、ステレオ。`-8`(LPC、mid/side)、ブロック長 1152(10 フレーム)、Vorbis コメント `TITLE=kiln testdata` | 基本動作、LPC、途中からの復号、壊れたフレーム(テストで書き換える) |
| `u8-mono.flac` | 8bit、8kHz、モノラル、2001 フレーム。`-0`(固定予測だけ)、ブロック長 576 | 8bit(WAV の符号なしとの変換)、固定予測、短い最後のフレーム |
| `s24-stereo.flac` | 24bit、48kHz、ステレオ(`-5`) | 24bit、形式の変換 |
| `s20-mono.flac` | 20bit、96kHz、モノラル、0.05 秒(`-5`)。24bit の器に 20bit の値を入れた EXTENSIBLE の WAV から作る | 器のビット数に満たないビット深度 |
| `s32-3ch.flac` | 32bit 整数、48kHz、3 チャンネル、0.05 秒(`-5`) | 32bit(side チャンネルが 33 ビット)、3 チャンネル |

## 作り直し方

```sh
python3 testdata/generate.py        # すべて(lame と flac が PATH にあること)
python3 testdata/generate.py wav    # WAV だけ(外部のツールは不要)
python3 testdata/generate.py flac   # FLAC だけ(flac が PATH にあること)
```

lame と flac のバージョンが変わると出力のバイト列も変わる。今の MP3 は LAME 64bits version 4.0(Homebrew)、FLAC は flac 1.5.0(Homebrew)で作った。作り直したら、ここのバージョンを更新し、テストの期待値(フレーム数など)を確かめること。
