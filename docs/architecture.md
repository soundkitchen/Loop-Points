# アーキテクチャ方針

コア API の形についての方針。2026-11-09 に合意した叩き台で、細部は実装しながら詰める。

## 1. 構成

- **コア**: I/O を持たない Zig のライブラリ。ファイルや OS には触れず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う。
- **CLI**: コアの薄いラッパー。ファイルの読み書きと引数処理だけを担う。
- **wasm**: `wasm32-freestanding` 向けの薄いラッパー。自前の export 関数(alloc / free / 各処理)に、薄い JS ラッパーを被せる。

### 1.1 ディレクトリとビルド

| パス | 内容 | ビルド成果物 |
|---|---|---|
| `src/root.zig` | コアのルート。モジュール名 `kiln` | — |
| `cli/main.zig` | CLI | `zig-out/bin/kiln` |
| `wasm/main.zig` | wasm の export 関数 | `zig-out/wasm/kiln.wasm` |
| `wasm/kiln.js` | JS ラッパー(ES module。`load()` で wasm を読み込む) | `zig-out/wasm/kiln.js` |
| `testdata/` | テスト用の音声(MP3 トリマーの実装時に追加する) | — |

- `zig build` は CLI と wasm の両方をビルドする。wasm は `-Dtarget` に関係なく常に `wasm32-freestanding` 向けで、最適化モードが debug のときは small でビルドする
- `zig build test` はコアと CLI のテストを実行し、wasm のビルドが通ることも確かめる(wasm はネイティブで実行できないため)
- バージョンは `build.zig.zon` の `.version` だけを出所にし、ビルドオプション経由でコアの `kiln.version` に渡す

## 2. コア API の方針

1. **エンコーダはストリーミングを基本にする**: `init → write(samples) を何度でも → finish` の形で、出力先は `*std.Io.Writer`。一括版は `std.Io.Writer.Allocating` で包んだ便利関数として用意する。長尺の音声を wasm の linear memory に一度に載せずに済むようにするため。
2. **後から確定するヘッダ値**(WAV のデータ長、FLAC の STREAMINFO など): `std.Io.Writer` はシークできないため、次の 2 つを併用する。
   - 長さが分かっているときは、最初に渡してもらう
   - `finish` が「先頭に上書きするヘッダのバイト列」を返し、書き戻しは呼び出し側が行う
3. **パーサ・トリマーはファイル全体の `[]const u8` を受け取る**: MP3 トリマーのようにタグ・ヘッダ・フレームを行き来する処理は、一括のほうが単純になる。
4. **アロケータは常に引数で明示的に渡す**(Zig 標準ライブラリの流儀)。
5. **エラーは Zig の error set で返す**。詳しい診断が必要な箇所だけ、診断情報の構造体を返す。

## 3. Zig 0.17.1 で確認したこと

試作(16bit WAV を `*Io.Writer` に書くコア)を、テスト・CLI・`wasm32-freestanding` の 3 通りで動かして確認した。

- `main` は `pub fn main(init: std.process.Init) !void` の形。`init` に `gpa` / `arena` / `io` / 引数 / 環境変数が入る。
- `std.Io.Reader` / `std.Io.Writer` はバッファを内部に持つ具体型(vtable 方式)。`Reader.fixed` / `Writer.fixed` / `Writer.Allocating` は OS なしで動き、wasm でもそのまま使える。
- ファイルは `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit)` で一括読み込み、`file.writer(io, &buf).interface` を `*Io.Writer` として書き出せる。
- wasm では `std.heap.wasm_allocator` が使える。試作の wasm は ReleaseSmall で約 3KB。
- ファズテストは `std.testing.fuzz` が使える。
- 最適化モードの型は `std.lang.Optimize` で、値は `.debug` / `.safe` / `.fast` / `.small`。以前の `std.builtin.OptimizeMode` と `.Debug` などは非推奨(0.18.0 の後に削除予定)。
- stdout / stderr は `Io.File.Writer.initStreaming` で書く。`.init` は位置指定書き込みなので、ファイルにリダイレクトすると先頭から書いてしまい、`>>` で追記しても既存の内容を上書きする(macOS で確認)。
