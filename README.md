# K!LN

音声を読み込み、クロップして、任意の形式で書き出すための Zig 製ライブラリです。CLI とブラウザ(wasm)の両方で動かすことを目指しています。

最初の到達点は、Google Gemini Lyria が出力する MP3 を、再エンコードせずにサンプル精度でトリムすることです。開発中のため、まだ機能はありません。

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

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `src/` | コア。I/O を持たず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う |
| `cli/` | CLI。ファイルの読み書きと引数処理だけを担う薄いラッパー |
| `wasm/` | wasm 向けの export 関数(`main.zig`)と JS ラッパー(`kiln.js`) |
| `testdata/` | テスト用の音声(lame で作った短い MP3 など。Lyria の実ファイルは入れない)。MP3 トリマーの実装時に追加する |
| `docs/` | 設計と調査の記録。仕様として扱う |

## ドキュメント

- [`docs/draft.md`](docs/draft.md): 構想と決定事項
- [`docs/architecture.md`](docs/architecture.md): アーキテクチャ方針
- [`docs/lyria-mp3.md`](docs/lyria-mp3.md): Lyria 出力 MP3 の調査と無劣化トリム方式
