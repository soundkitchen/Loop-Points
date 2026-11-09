# テスト用の音声

コアのテストが使う MP3。どれも 2 秒の合成音(チャンネルごとに周波数の違う正弦波のスイープに、小さなノイズを混ぜたもの)を lame でエンコードしたもの。テストからは `testdata.zig` 経由で `@embedFile` する。

| ファイル | 構成 | 確かめたいこと |
|---|---|---|
| `lyria-like.mp3` | CBR 192kbps、44.1kHz、joint stereo、Xing/LAME タグなし。先頭に C2PA の `GEOB` を 1 つ持つ ID3v2.3(中身は仮のバイト列) | Lyria の出力と同じ構成での基本動作、C2PA を引き継がないこと |
| `cbr128-lame.mp3` | CBR 128kbps、44.1kHz、joint stereo、Info + LAME タグ付き | LAME タグ付きの入力(タイムラインの 0 が delay の後になる) |
| `vbr-lame.mp3` | VBR(`-V 4`)、44.1kHz、joint stereo、Xing + LAME タグ付き | VBR の出力(`Xing` タグと TOC) |
| `mono48k-notag.mp3` | CBR 48kbps、48kHz、モノラル、タグなし | Info フレームのビットレートの引き上げ、ビットリザーバが深いときの carrier |

## 作り直し方

```sh
python3 testdata/generate.py   # lame が PATH にあること
```

lame のバージョンが変わると出力のバイト列も変わる。今のファイルは LAME 64bits version 4.0(Homebrew)で作った。作り直したら、ここのバージョンを更新し、テストの期待値(フレーム数など)を確かめること。
