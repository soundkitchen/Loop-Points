# テスト用の音声

コアのテストが使う MP3、WAV、FLAC、Ogg、m4a、aac。テストからは `testdata.zig` 経由で `@embedFile` する。

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

## Ogg / m4a / aac

MP3 と同じ合成音(0.5 秒。ALAC は 0.25 秒)を、各ツールでエンコードしたもの。ffmpeg はメタデータを書かない(`-map_metadata -1`、`-fflags +bitexact`)。

| ファイル | 構成 | 確かめたいこと |
|---|---|---|
| `opus-stereo.opus` | opusenc、32kbps、ステレオ。元は 44.1kHz | Opus の基本動作、pre-skip(312)、元のレート(`input_sample_rate`) |
| `opus-mono-ffmpeg.opus` | ffmpeg(libopus)、24kbps、モノラル 48kHz | 別のエンコーダの Opus |
| `vorbis-stereo.ogg` | oggenc `-q 0`、44.1kHz ステレオ。音声は 2 ページ | Vorbis の設定ヘッダ、最初のページのグラニュール位置(テストで書き換える)、壊れたページ |
| `vorbis-mono22k.ogg` | oggenc `-q 2`、22.05kHz モノラル | 別のブロックの長さとモード |
| `aac-lc-ffmpeg.m4a` | ffmpeg の AAC-LC、64kbps、44.1kHz ステレオ | 編集リスト(遅延 1024)、後方互換の「SBR なし」の印 |
| `aac-lc-afconvert.m4a` | afconvert の AAC-LC、44.1kHz ステレオ | iTunSMPB(遅延 2112)、SBR の印のない AudioSpecificConfig |
| `aac-he-afconvert.m4a` | afconvert の HE-AAC、48kbps。出力 44.1kHz、中心 22.05kHz | SBR の印、タイムスケールが中心のレートのときの iTunSMPB |
| `aac-hev2-afconvert.m4a` | afconvert の HE-AAC v2、32kbps。中心はモノラル | PS の印(出力は 2 チャンネル) |
| `alac-afconvert.m4a` | afconvert の ALAC、16bit 44.1kHz ステレオ | ALAC の設定 |
| `lc-ffmpeg.aac` | ffmpeg の AAC-LC の ADTS、64kbps、44.1kHz ステレオ | ADTS の基本動作 |
| `lc-afconvert.aac` | afconvert の AAC-LC の ADTS | 別のエンコーダの ADTS |
| `he-afconvert.aac` | afconvert の HE-AAC の ADTS、48kbps | ヘッダでは 22.05kHz の AAC-LC に見えること |

## 作り直し方

```sh
python3 testdata/generate.py        # すべて(lame、flac、opusenc、oggenc、ffmpeg、afconvert が PATH にあること。afconvert は macOS にしかない)
python3 testdata/generate.py wav    # WAV だけ(外部のツールは不要)
python3 testdata/generate.py flac   # FLAC だけ(flac が PATH にあること)
python3 testdata/generate.py ogg    # Ogg だけ(opusenc、oggenc、ffmpeg が PATH にあること)
python3 testdata/generate.py m4a    # m4a だけ(ffmpeg、afconvert。afconvert は macOS にしかない)
python3 testdata/generate.py aac    # aac だけ(ffmpeg、afconvert)
```

ツールのバージョンが変わると出力のバイト列も変わる。今の MP3 は LAME 64bits version 4.0(Homebrew)、FLAC は flac 1.5.0(Homebrew)、Ogg / m4a / aac は opus-tools 0.2(libopus 1.6.1)、vorbis-tools 1.4.3、ffmpeg 9.0.2(すべて Homebrew)、macOS 26.6.2 の afconvert で作った。作り直したら、ここのバージョンを更新し、テストの期待値(フレーム数など)を確かめること。
