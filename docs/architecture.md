# アーキテクチャ方針

コア API の形についての方針。2026-11-09 に合意した叩き台で、細部は実装しながら詰める。

## 1. 構成

- **コア**: I/O を持たない Zig のライブラリ。ファイルや OS には触れず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う。
- **CLI**: コアの薄いラッパー。ファイルの読み書きと引数処理だけを担う。
- **wasm**: `wasm32-freestanding` 向けの薄いラッパー。自前の export 関数(alloc / free / 各処理)に、薄い JS ラッパーを被せる。

### 1.1 ディレクトリとビルド

| パス | 内容 | ビルド成果物 |
|---|---|---|
| `src/root.zig` | コアのルート。モジュール名 `kiln`。入力の形式の判定(`kiln.detect`)もここに置く | — |
| `src/pcm.zig` | PCM のサンプル形式と、f32 との変換(`kiln.pcm`) | — |
| `src/mp3.zig`, `src/mp3/` | MP3 の解析と無劣化トリム(`kiln.mp3`)。`frame`(フレームヘッダ)/ `id3` / `xing`(Xing・LAME タグ)/ `stream`(入力の解析)/ `trim` に分ける | — |
| `src/wav.zig`, `src/wav/` | WAV の解析とサンプル精度のトリム、エンコーダ(`kiln.wav`)。`parse`(チャンクの解析)/ `header`(ヘッダの書き出し)/ `encoder` に分ける | — |
| `cli/main.zig` | CLI | `zig-out/bin/kiln` |
| `wasm/main.zig` | wasm の export 関数 | `zig-out/wasm/kiln.wasm` |
| `wasm/kiln.js` | JS ラッパー(ES module。`load()` で wasm を読み込む) | `zig-out/wasm/kiln.js` |
| `LICENSE` | MIT の全文。wasm の配布物にも置く | `zig-out/wasm/LICENSE` |
| `THIRD_PARTY_NOTICES.md` | 外部から取り込んだコードや数表の出所とライセンス(方針は [`draft.md`](draft.md) §2.5) | — |
| `cli/time.zig` | CLI の時刻指定(`1.5` / `1:02.5` / `66150s`)の解析 | — |
| `testdata/` | テスト用の音声(MP3 と WAV)と、それを `@embedFile` するモジュール(`testdata.zig`)。作り方は `testdata/README.md` | — |

- `zig build` は CLI と wasm の両方をビルドする。wasm は `-Dtarget` に関係なく常に `wasm32-freestanding` 向けで、最適化モードが debug のときは small でビルドする
- `zig build test` はコアと CLI のテストを実行し、wasm のビルドが通ることも確かめる(wasm はネイティブで実行できないため)
- コアのテストは、`testdata` モジュールを import できるテスト専用のモジュール(ルートは同じ `src/root.zig`)で実行する。ライブラリとしての `kiln` モジュールには `testdata` を含めない。`src/` の各ファイルはトップレベルに `const testdata = @import("testdata");` を置き、`test` ブロックからだけ参照する(Zig はトップレベルの宣言を参照されたときにだけ解析するため、テスト以外のビルドでは import が解決されない)
- ライブラリ・wasm・テストの各ビルドで使うコアのモジュールは、`build.zig` の `kilnModuleOptions` で同じ定義から作る。テスト用のモジュールは、それに `testdata` の import を足したもの
- バージョンは `build.zig.zon` の `.version` だけを出所にし、ビルドオプション経由でコアの `kiln.version` に渡す

## 2. コア API の方針

1. **エンコーダはストリーミングを基本にする**: `init → write(samples) を何度でも → finish` の形で、出力先は `*std.Io.Writer`。一括版は `std.Io.Writer.Allocating` で包んだ便利関数として用意する。長尺の音声を wasm の linear memory に一度に載せずに済むようにするため。
2. **後から確定するヘッダ値**(WAV のデータ長、FLAC の STREAMINFO など): `std.Io.Writer` はシークできないため、次の 2 つを併用する。
   - 長さが分かっているときは、最初に渡してもらう
   - `finish` が「先頭に上書きするヘッダのバイト列」を返し、書き戻しは呼び出し側が行う
3. **パーサ・トリマーはファイル全体の `[]const u8` を受け取る**: MP3 トリマーのようにタグ・ヘッダ・フレームを行き来する処理は、一括のほうが単純になる。
4. **アロケータは常に引数で明示的に渡す**(Zig 標準ライブラリの流儀)。
5. **エラーは Zig の error set で返す**。詳しい診断が必要な箇所だけ、診断情報の構造体を返す。

### 2.1 MP3 トリムの API

```zig
const info = try kiln.mp3.probe(input);          // sample_rate, channels, samples, frames, min_start
const r = try kiln.mp3.trim(input, .{ .start = 66150, .end = 441000 }, writer); // *std.Io.Writer
// r.start / r.end: 丸めた後の区間。end を null にすると末尾まで。r.sample_rate: 入力のサンプルレート
const t = try kiln.mp3.trimAlloc(gpa, input, .{ .start = 66150 }); // t.data / t.start / t.end / t.sample_rate
```

- 位置はタイムライン上のサンプル位置([`lyria-mp3.md`](lyria-mp3.md) §5.1)。秒からの変換は CLI と JS 側で行う
- 範囲外の指定はコアが丸め、実際に切り出した区間を返す。丸めたことを利用者に伝えるのは呼び出し側(CLI は stderr に警告を出す)
- `trim` は入力のスライスをそのまま `Writer` に書くため、アロケータを使わない

### 2.2 CLI

```sh
kiln trim <input> <output> [--start TIME] [--end TIME | --duration TIME] [--format FORMAT]
```

- `<input>` / `<output>` は `-` で stdin / stdout
- 入力の形式(MP3 / WAV)は、コアの `kiln.detect` が判定する。拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)で判定し、それ以外は MP3 の解析に任せる(先頭にゴミがある MP3 も受け付ける)
- `--format mp3|wav` で出力の形式を指定する。省くと入力と同じ形式。形式の変換はまだできないので、入力と違う形式を指定するとエラー(終了コード 1)
- TIME は秒(`1.5`)、分:秒 / 時:分:秒(`1:02.5`)、サンプル数(`66150s`)。秒は浮動小数点を使わずに解析し、切り捨てでサンプル位置にする
- `--duration` は、切り上げた後の実際の開始位置から数える(タグなしの入力で `--start` を省いても、出力の長さは指定どおり)
- 出力ファイルは一時ファイルに書き、最後まで書けたときだけ置き換える(`Dir.createFileAtomic`)。失敗したときは、既存の出力ファイルは元のまま残る。置き換えはリネームなので、出力先がシンボリックリンクならリンク自体が置き換わる
- 終了コード: 0 = 成功、1 = 処理の失敗(入力が MP3 / WAV でない、区間が空など)、2 = 引数の誤り

### 2.3 wasm と JS

- export 関数は成功なら true を返し、結果(出力のバイト列や数値)をモジュール内の変数に置く。JS 側は `kiln_output_ptr` / `kiln_output_len` / `kiln_value(i)` で読み出し、失敗時は `kiln_error_ptr` / `kiln_error_len` でエラー名を読む
- JS ラッパーは `load()` が返すオブジェクトに `mp3.probe(bytes)` / `mp3.trim(bytes, { start, end })`(秒)/ `{ startSample, endSample }`(サンプル数)を持つ。失敗時はコアのエラー名を `code` に持つ `KilnError` を投げる
- 入力は `BufferSource`(`ArrayBuffer` / TypedArray / `DataView`)。TypedArray と `DataView` は、要素の値ではなく下のバイト列として読む
- `wav.probe(bytes)` / `wav.trim(bytes, options)` は MP3 と同じ形(`probe` の `format` は `'u8'` / `'i16'` / `'i24'` / `'i32'` / `'f32'` / `'f64'`)。`wav.encode(source, { sampleRate, format = 'i16', dither = 'tpdf' })` は、`decodeAudioData` が返す `AudioBuffer`(`sampleRate` は省ける)か、チャンネルごとの `Float32Array` の配列から WAV のバイト列を作る
- `wav.encode` のサンプルは、`kiln_alloc_f32` で確保した領域(4 バイト境界)にチャンネルごとに続けて書き、`kiln_wav_encode` に渡す。形式は `kiln.pcm.Format` の番号でやり取りする(JS 側の `FORMATS` と並びを合わせる)
- `mp3.trim` / `wav.trim` は、秒で指定されたときだけ、サンプルレートを知るために先に `kiln_mp3_probe` / `kiln_wav_probe` を呼ぶ。サンプル数だけの指定では入力の解析は 1 回で済む(戻り値の秒は `kiln_mp3_trim` / `kiln_wav_trim` が返すサンプルレートで計算する)
- `startSample` / `endSample` に BigInt を渡すときは 0 以上 2^64 未満でなければ `RangeError` にする(u64 の引数で桁あふれしないように)
- サンプル位置は u64 なので、export 関数の引数・戻り値は JS では BigInt になる

### 2.4 PCM

```zig
// 形式: .u8(8bit 符号なし)/ .i16 / .i24(3 バイト詰め)/ .i32 / .f32 / .f64。リトルエンディアン、インターリーブ
kiln.pcm.toF32(.i24, bytes, samples);            // バイト列 → f32
var q: kiln.pcm.Quantizer = .init(.tpdf);        // .none なら四捨五入とクリップだけ
kiln.pcm.fromF32(.i16, samples, bytes, &q);      // f32 → バイト列
```

- PCM は読み込んだ元の形式のまま持ち、必要なときだけ f32 と変換する(WAV → WAV などを無劣化にするため)
- 整数と浮動小数点の対応は `値 / 2^(bits - 1)`。16 / 24bit と 8bit は、整数 → f32 → 整数で元に戻る
- 整数への変換では、既定で TPDF ディザ(振幅 ±1 LSB)をかける。丸めは 0 から遠い方への四捨五入(`@round`。JS の `Math.round` とは負の .5 で結果が違う)。乱数の種は固定なので、同じ入力からは毎回同じ結果になる。範囲外の値はクリップし、NaN は 0 にする。浮動小数点への変換ではクリップしない

### 2.5 WAV

```zig
const info = try kiln.wav.probe(input);          // sample_rate, channels, format(kiln.pcm.Format), samples
const r = try kiln.wav.trim(input, .{ .start = 44100, .end = 88200 }, writer);
const t = try kiln.wav.trimAlloc(gpa, input, .{ .start = 44100 });
```

- 扱う形式: RIFF / WAVE の PCM(8bit 符号なし、16 / 24 / 32bit 整数)と浮動小数点(32 / 64bit)。WAVE_FORMAT_EXTENSIBLE は SubFormat で判断する。RF64、RIFX(ビッグエンディアン)、ADPCM などの圧縮形式は `UnsupportedFormat`
- 位置はフレーム(チャンネルあたりのサンプル)単位で、先頭を 0 とする。範囲外の指定は MP3 と同じく丸める
- トリムは `data` の中身を切り出すだけなので無劣化。`fmt ` チャンクは入力のものをそのまま書き、ほかのチャンク(`LIST`、`fact` など)は引き継がない
- `data` の長さが入力を超える(長さを 0xFFFFFFFF にしたストリーミング出力や、途中で切れたファイル)ときは、入力の終わりまでとみなし、フレームの区切りで切り詰める
- 出力が 4GiB 以上になるときは `TooLarge`(RF64 では書かない)

```zig
// ストリーミングのエンコーダ(§2 の方針)
var e: kiln.wav.Encoder = try .init(writer, .{ .sample_rate = 44100, .channels = 2, .format = .i16, .frames = n });
try e.writeF32(interleaved);                     // writePlanarF32(&.{ left, right }) / writeRaw(bytes) も
const header = try e.finish();                   // .frames を渡さなかったときだけ、書き戻すヘッダが返る
// 一括版: チャンネルごとの f32(Web Audio の AudioBuffer と同じ並び)から
const bytes = try kiln.wav.encodePlanarAlloc(gpa, &.{ left, right }, .{ .sample_rate = 44100 });
```

- 既定の形式は 16bit 整数、ディザは TPDF(§2.4)
- 1 フレームのバイト数(チャンネル数 × サンプルのバイト数)が 65535 を超えるとき、またはサンプルレート × 1 フレームのバイト数が 32bit に収まらないときは `InvalidOptions`(`fmt ` の nBlockAlign / nAvgBytesPerSec に書けないため)
- 2 チャンネル以下は WAVE_FORMAT_PCM / IEEE_FLOAT、3 チャンネル以上は WAVE_FORMAT_EXTENSIBLE で書く(チャンネルマスクは先頭から順に割り当てる)。浮動小数点でも `fact` チャンクは書かない
- フレーム数を渡すと、正しい長さのヘッダを先に書き、`finish` で書いた長さと合うかを確かめる(違えば `LengthMismatch`)。渡さないと長さを 0xFFFFFFFF にしたヘッダを書き、`finish` が正しいヘッダを返す
- 中身が奇数バイトのときの詰め物は、フレーム数を渡したときだけ書く。渡さないときは、書き戻せないパイプなどで詰め物がサンプルとして読まれないよう書かず、`finish` が返すヘッダの RIFF サイズにも含めない

## 3. Zig 0.17.1 で確認したこと

試作(16bit WAV を `*Io.Writer` に書くコア)を、テスト・CLI・`wasm32-freestanding` の 3 通りで動かして確認した。

- `main` は `pub fn main(init: std.process.Init) !void` の形(終了コードを返すなら `!u8`。K!LN の CLI は `!u8`)。`init` に `gpa` / `arena` / `io` / 引数 / 環境変数が入る。
- `std.Io.Reader` / `std.Io.Writer` はバッファを内部に持つ具体型(vtable 方式)。`Reader.fixed` / `Writer.fixed` / `Writer.Allocating` は OS なしで動き、wasm でもそのまま使える。
- ファイルは `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit)` で一括読み込み、`file.writer(io, &buf).interface` を `*Io.Writer` として書き出せる。
- wasm では `std.heap.wasm_allocator` が使える。試作の wasm は ReleaseSmall で約 3KB。
- ファズテストは `std.testing.fuzz` が使える。
- 最適化モードの型は `std.lang.Optimize` で、値は `.debug` / `.safe` / `.fast` / `.small`。以前の `std.builtin.OptimizeMode` と `.Debug` などは非推奨(0.18.0 の後に削除予定)。
- 配列の繰り返し演算子 `**` は使えない(`"ab" ** 2` は構文エラー)。0 で埋めた配列は `@splat(0)` で作る。
- CRC-16/ARC(LAME タグの CRC)は `std.hash.crc.@"CRC-16/ARC"` にある。
- wasm32 の export 関数が返すポインタ・長さ(usize)は、JS には符号付きの i32 として見える。2GiB 以上のアドレスや、長さ 0 の確保で `wasm_allocator` が返すダミーのアドレス(0xFFFFFFFF)が負になるため、JS 側で `>>> 0` して扱う。
- enum と整数の変換: `@typeInfo(E).@"enum"` のフィールドは `field_names` / `field_values`(`fields` はない)。範囲を確かめて整数から enum にするには `std.enums.fromInt(E, n)`(範囲外なら null)。`@enumFromInt` を書くと、`zig fmt` が `@fromBackingInt(@intCast(...))` に書き換える
- stdout / stderr は `Io.File.Writer.initStreaming` で書く。`.init` は位置指定書き込みなので、ファイルにリダイレクトすると先頭から書いてしまい、`>>` で追記しても既存の内容を上書きする(macOS で確認)。
