# K!LN

音声を読み込み、クロップして、任意の形式で書き出すための Zig 製ライブラリです。CLI とブラウザ(wasm)の両方で動かすことを目指しています。

最初の到達点は、Google Gemini Lyria が出力する MP3 を、再エンコードせずにサンプル精度でトリムすることです。今のところ、MP3(MPEG-1 Layer III)の無劣化トリムだけができます。

- 表示名は `K!LN`、識別子(リポジトリ名・モジュール名・実行ファイル名)は `kiln` です。

## 必要なもの

- Zig 0.17.1
  - このリポジトリでは direnv(`.envrc`)で `~/Zig/0.17` を PATH に通します。初回は `direnv allow` を実行してください。

## ビルドとテスト

```sh
zig build          # CLI(zig-out/bin/kiln)と wasm(zig-out/wasm/)をビルド
zig build test     # テストを実行(wasm のビルドも含む)
zig build run -- --version
zig build wasm     # wasm と JS ラッパーだけをビルド
```

## 使い方

### CLI

```sh
kiln trim in.mp3 out.mp3 --start 1.5 --end 10       # 1.5 秒から 10 秒まで
kiln trim in.mp3 out.mp3 --start 1:02.5 --duration 30
kiln trim in.mp3 - --start 66150s > out.mp3         # サンプル数で指定。- は stdout
```

- 再エンコードせずに切り出し、ffmpeg や Chrome / Safari でデコードしたときに、元ファイルの該当区間とサンプル単位で一致します(方式は [`docs/lyria-mp3.md`](docs/lyria-mp3.md))
- 位置は ffmpeg でデコードしたときの先頭を 0 とします。LAME タグのない MP3(Lyria の出力など)では、先頭 529 サンプルより前からは切り出せません(指定すると 529 に切り上げます)
- 入力の ID3v2 タグ(Lyria の C2PA マニフェストを含む)は引き継ぎません

### ブラウザ(wasm)

`zig build` で `zig-out/wasm/` にできる `kiln.wasm` と `kiln.js` を同じ場所に置いて使います。

```js
import { load } from './kiln.js';

const kiln = await load();
const bytes = new Uint8Array(await file.arrayBuffer());
const info = kiln.mp3.probe(bytes);                 // { sampleRate, channels, samples, duration, ... }
const { data } = kiln.mp3.trim(bytes, { start: 1.5, end: 10 }); // 秒。startSample / endSample でサンプル数も可
const blob = new Blob([data], { type: 'audio/mpeg' });
```

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `src/` | コア。I/O を持たず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う |
| `cli/` | CLI。ファイルの読み書きと引数処理だけを担う薄いラッパー |
| `wasm/` | wasm 向けの export 関数(`main.zig`)と JS ラッパー(`kiln.js`) |
| `testdata/` | テスト用の音声(lame で作った短い MP3。Lyria の実ファイルは入れない)。作り方は [`testdata/README.md`](testdata/README.md) |
| `docs/` | 設計と調査の記録。仕様として扱う |

## ドキュメント

- [`docs/draft.md`](docs/draft.md): 構想と決定事項
- [`docs/architecture.md`](docs/architecture.md): アーキテクチャ方針
- [`docs/lyria-mp3.md`](docs/lyria-mp3.md): Lyria 出力 MP3 の調査と無劣化トリム方式
