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
| `src/mp3.zig`, `src/mp3/` | MP3 の解析と無劣化トリム(`kiln.mp3`)。`frame`(フレームヘッダ)/ `id3` / `xing`(Xing・LAME タグ)/ `stream`(入力の解析)/ `trim` に分ける。デコーダは `bits`(ビット読み取り)/ `huffman` / `layer3`(周波数領域の処理)/ `synth`(IMDCT と合成フィルタ)/ `decoder`(設計は [`mp3-decoder.md`](mp3-decoder.md)) | — |
| `src/wav.zig`, `src/wav/` | WAV の解析とサンプル精度のトリム、エンコーダ(`kiln.wav`)。`parse`(チャンクの解析)/ `header`(ヘッダの書き出し)/ `encoder` に分ける | — |
| `src/flac.zig`, `src/flac/` | FLAC の解析・復号・書き出し(`kiln.flac`)。`bits`(ビットの読み書き)/ `frame`(フレームヘッダ)/ `metadata`(`fLaC` とメタデータブロック)/ `stream`(フレームの区切り)/ `decoder`(サブフレームの復号)/ `encoder`(エンコーダ)/ `lpc`(線形予測の分析)/ `trim`(FLAC → FLAC の切り出し)に分ける(設計は [`flac.md`](flac.md)) | — |
| `cli/main.zig` | CLI | `zig-out/bin/kiln` |
| `wasm/main.zig` | wasm の export 関数 | `zig-out/wasm/kiln.wasm` |
| `wasm/kiln.js` | JS ラッパー(ES module。`load()` で wasm を読み込む) | `zig-out/wasm/kiln.js` |
| `wasm/kiln.d.ts` | JS ラッパーの TypeScript の型定義(TypeScript 5.7 以降) | `zig-out/wasm/kiln.d.ts` |
| `wasm/types/` | kiln.d.ts の型検査用のファイル(DOM / WebWorker / ES だけの 3 通り)。配布物には含めない | — |
| `LICENSE` | MIT の全文。wasm の配布物にも置く | `zig-out/wasm/LICENSE` |
| `THIRD_PARTY_NOTICES.md` | 外部から取り込んだコードや数表の出所とライセンス(方針は [`draft.md`](draft.md) §2.5) | — |
| `cli/time.zig` | CLI の時刻指定(`1.5` / `1:02.5` / `66150s`)の解析 | — |
| `testdata/` | テスト用の音声(MP3、WAV、FLAC)と、それを `@embedFile` するモジュール(`testdata.zig`)。作り方は `testdata/README.md` | — |

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

```zig
// デコード: 区間の PCM をインターリーブした f32 で sink.writeF32 に渡す(kiln.wav.Encoder をそのまま渡せる)
const d = try kiln.mp3.decode(input, .{ .start = 0, .end = 44100 }, &sink); // d.start / d.end / d.sample_rate / d.channels / d.invalid_frames
// WAV にする(入力の解析は 1 回)。toWavAlloc は出力の大きさを計算して一度に確保する一括版
const r = try kiln.mp3.toWav(input, .{ .start = 0 }, .{ .format = .i16, .dither = .tpdf }, writer);
const t = try kiln.mp3.toWavAlloc(gpa, input, .{ .start = 0 }, .{});   // t.data / t.result
var dec: kiln.mp3.Decoder = .{};                  // 1 フレームずつの低レベル API
const nch = try dec.decodeFrame(frame_bytes, &pcm); // pcm: [2][1152]f32。扱えないフレームは InvalidFrame
```

- MP3 → FLAC は `kiln.mp3.toFlac`(`*Io.Writer` に書き、STREAMINFO の書き戻しを返す)と一括版の `toFlacAlloc`(§2.6)。位置と区間の扱いは `toWav` と同じ
- `decode` / `toWav` の位置はトリムと同じタイムライン。ただしタグなしの入力でも先頭を 529 に切り上げない(デコードでは先頭のデコーダ遅延も出力できるため)
- 復号は区間の少し手前のフレームから始める(結果は先頭から復号したときと同じ。[`mp3-decoder.md`](mp3-decoder.md) §2)
- `invalid_frames` は、区間にかかったフレームのうち、サイド情報が壊れていて復号できなかったものの数

### 2.2 CLI

```sh
kiln trim <input> <output> [--start TIME] [--end TIME | --duration TIME]
          [--format FORMAT] [--sample-format SAMPLE] [--bits N]
          [--compression N] [--dither DITHER]
```

- `<input>` / `<output>` は `-` で stdin / stdout
- 入力の形式(MP3 / WAV / FLAC)は、コアの `kiln.detect` が判定する。拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)、FLAC は先頭(ID3v2 タグがあればその後)の `fLaC` か Ogg FLAC の印で判定し、それ以外は MP3 の解析に任せる(先頭にゴミがある MP3 も受け付ける)
- `--format mp3|wav|flac` で出力の形式を指定する。省くと入力と同じ形式。変換できるのは MP3 / FLAC → WAV と WAV / MP3 → FLAC で、ほかの組み合わせ(MP3 への変換)はエラー(終了コード 1)。FLAC → FLAC は切り出し(`kiln.flac.trim`。境目のフレームだけ作り直す。[`flac.md`](flac.md) §7)
- WAV に変換するときだけ `--sample-format u8|i16|i24|i32|f32|f64` を使う。形式の既定は、MP3 は `i16`、FLAC はビット深度を保つ形式([`flac.md`](flac.md) §4)
- WAV / MP3 を FLAC に変換するときだけ `--bits 4〜32`(既定は、整数の WAV なら元のビット深度、それ以外は 16)と `--compression 0〜8`(既定は 5。flac コマンドの -0〜-8 と同じ。[`flac.md`](flac.md) §6)を使う
- `--dither tpdf|none`(既定は `tpdf`)は変換するときだけ使う。オプションを使わない組み合わせで指定すると引数の誤り(終了コード 2)
- FLAC の入力は、フレームの一覧(`kiln.flac.Index`)を 1 回だけ作り、長さを求めるのと、切り出し・WAV への変換(`Index.trim` / `Index.toWav`)で使い回す(区切りを探す走査を繰り返さない)
- FLAC は STREAMINFO を最後に書き戻す。ファイルへはフレームを流して書き(`kiln.wav.toFlac` / `kiln.mp3.toFlac` / `kiln.flac.Index.trim`)、閉じる前に先頭の STREAMINFO を位置を指定して書き戻す(`File.writePositionalAll`。出力全体をメモリにためない)。stdout へは書き戻せないので、メモリ上で書き戻してから書く
- MP3 → WAV / FLAC では、タグなしの入力でも先頭を 529 に切り上げない(`kiln.mp3.decode` と同じ)。MP3 / FLAC → WAV、MP3 → FLAC、FLAC → FLAC で復号できなかったフレームがあれば、その数を stderr に警告する(終了コードは 0。FLAC → FLAC では無音として作り直したフレームの数)
- TIME は秒(`1.5`)、分:秒 / 時:分:秒(`1:02.5`)、サンプル数(`66150s`)。秒は浮動小数点を使わずに解析し、切り捨てでサンプル位置にする
- `--duration` は、切り上げた後の実際の開始位置から数える(タグなしの入力で `--start` を省いても、出力の長さは指定どおり)
- 出力ファイルは一時ファイルに書き、最後まで書けたときだけ置き換える(`Dir.createFileAtomic`)。失敗したときは、既存の出力ファイルは元のまま残る。置き換えはリネームなので、出力先がシンボリックリンクならリンク自体が置き換わる
- 終了コード: 0 = 成功、1 = 処理の失敗(入力が MP3 / WAV / FLAC でない、区間が空など)、2 = 引数の誤り

### 2.3 wasm と JS

- JS に返すエラーの名前は、wasm/main.zig の `KilnError`(エラーの集合)に限る。`fail` はこの集合しか受け付けないので、export が新しいエラーを返しうるようになるとコンパイルが通らなくなる。kiln.d.ts の `KilnErrorCode` も同じ一覧にする(この同期は手作業。両方の定義の横に、もう一方を指すコメントがある)
- `InternalError` は kiln の不具合(起きるはずのない食い違い。たとえば MP3 → WAV で書いた長さが WAV のヘッダと違う)のときに返す。止めずにエラーとして返すので、wasm のインスタンスはそのまま使い続けられる。CLI は終了コード 1
- 型定義(kiln.d.ts)は ES の標準の型だけを使い、DOM / WebWorker の型(`BufferSource`、`URL`、`WebAssembly` など)に頼らない。入力は `ArrayBufferLike | ArrayBufferView`(kiln.js がバイト列として読むものすべて)、出力は `Uint8Array<ArrayBuffer>` / `Float32Array<ArrayBuffer>`(そのまま `Blob` などに渡せる)。`wav.encode` は `AudioBuffer` を構造で受け(Worker の型ライブラリにも通る)、`Float32Array[]` を渡すときは `sampleRate` が必須。`load` の URL は文字列か、`href` を持つもの(`URL` など)
- kiln.d.ts か kiln.js の API を変えたら、TypeScript 5.7 以降の tsc で `wasm/types/` の 3 つの設定(`tsconfig.dom.json` / `tsconfig.worker.json` / `tsconfig.es.json`)の型検査を通す(`tsc -p wasm/types/tsconfig.dom.json` など)。誤った使い方が型エラーになることも `@ts-expect-error` で確かめている。zig build は型検査をしない(Node と tsc を前提にしないため)
- export 関数は成功なら true を返し、結果(出力のバイト列や数値)をモジュール内の変数に置く。JS 側は `kiln_output_ptr` / `kiln_output_len` / `kiln_value(i)` で読み出し、失敗時は `kiln_error_ptr` / `kiln_error_len` でエラー名を読む
- JS ラッパーは `load()` が返すオブジェクトに `mp3.probe(bytes)` / `mp3.trim(bytes, { start, end })`(秒)/ `{ startSample, endSample }`(サンプル数)を持つ。失敗時はコアのエラー名を `code` に持つ `KilnError` を投げる
- 入力は `ArrayBuffer` / `SharedArrayBuffer` / TypedArray / `DataView`(型定義の `BytesInput`)。TypedArray と `DataView` は、要素の値ではなく下のバイト列として読む
- `wav.probe(bytes)` / `wav.trim(bytes, options)` は MP3 と同じ形(`probe` の `format` は `'u8'` / `'i16'` / `'i24'` / `'i32'` / `'f32'` / `'f64'`)。`wav.encode(source, { sampleRate, format = 'i16', dither = 'tpdf' })` は、`decodeAudioData` が返す `AudioBuffer`(`sampleRate` は省ける)か、チャンネルごとの `Float32Array` の配列から WAV のバイト列を作る
- `mp3.decode(bytes, options)` は、区間をデコードしてチャンネルごとの `Float32Array` を `channels` に返す(`AudioBuffer` の `getChannelData` と同じ並び)。`mp3.toWav(bytes, { ...区間, format = 'i16', dither = 'tpdf' })` は WAV のバイト列を返し、大きな PCM を JS に引き出さずに済む。位置の指定は `trim` と同じ
- `mp3.decode` / `mp3.toWav` / `mp3.toFlac` の戻り値の `invalidFrames` は、復号できなかった(無音にした)フレームの数
- FLAC の書き出しは `flac.encode(source, { sampleRate, bitsPerSample = 16, compression = 5, dither = 'tpdf' })`(`wav.encode` と同じく AudioBuffer か `Float32Array[]`)、`wav.toFlac(bytes, { ...区間, bitsPerSample, compression, dither })`(`bitsPerSample` の既定は整数の WAV なら元のビット深度)、`mp3.toFlac(bytes, { ...区間, bitsPerSample = 16, compression, dither })`。`bitsPerSample`(4〜32 の整数)と `compression`(0〜8 の整数)が外れれば JS 側で `RangeError`
- `flac.trim(bytes, 区間)` は FLAC のまま切り出し、`{ data, ...区間, invalidFrames }` を返す。`kiln_flac_trim` の `kiln_value` は 0: start、1: end、2: サンプルレート、4: 壊れたフレームの数(3 は 0)
- `kiln_flac_encode` / `kiln_wav_to_flac` / `kiln_mp3_to_flac` の `kiln_value` は、それぞれ `kiln_wav_encode`(なし)/ `kiln_wav_trim` / `kiln_mp3_decode` と同じ並び。`kiln_wav_to_flac` は `has_bits` が false のときにビット深度をコアに任せる。AudioBuffer を写す処理(`withPlanar`)は `wav.encode` と `flac.encode` で共通
- `flac.probe(bytes)` は `{ sampleRate, channels, bitsPerSample, samples, frames, duration }` を返す。`flac.decode` / `flac.toWav` は `mp3.decode` / `mp3.toWav` と同じ形で、`flac.decode` の値は整数のサンプルを 2^(bitsPerSample - 1) で割ったもの。`flac.toWav` の `format` を省くとビット深度を保つ形式(元の PCM のまま)。`kiln_flac_to_wav` は `has_format` が false のときに形式をコアに任せる
- `kiln_flac_decode` / `kiln_flac_to_wav` の `kiln_value` の並びは MP3 と同じ。`kiln_flac_probe` は 0: サンプルレート、1: チャンネル数、2: ビット深度、3: サンプル数、4: フレーム数。`kiln_flac_format` はメタデータ(STREAMINFO)だけを読み、0: サンプルレート、1: チャンネル数、2: ビット深度を置く(フレームを走査しないので軽い)
- デコードした PCM をチャンネルごとの f32 に並べる sink(`PlanarSink`)は MP3 と FLAC で共通。FLAC の整数は 2^-(bits - 1) を掛けて f32 にする
- `kiln_mp3_decode` は、チャンネルごとに並べた f32 を出力のバイト列に置き、チャンネル数を `kiln_value(3)`、復号できなかったフレームの数を `kiln_value(4)` で返す。`kiln_mp3_to_wav` も同じ並び(0: start、1: end、2: サンプルレート、3: チャンネル数、4: 復号できなかったフレームの数)で返す。WAV は `kiln.mp3.toWavAlloc` で作り、入力の解析は 1 回、出力は前もって計算した大きさで一度に確保する
- `wav.encode` のサンプルは、`kiln_alloc_f32` で確保した領域(4 バイト境界)にチャンネルごとに続けて書き、`kiln_wav_encode` に渡す。形式は `kiln.pcm.Format` の番号でやり取りする(JS 側の `FORMATS` と並びを合わせる)
- `mp3.trim` / `mp3.decode` / `mp3.toWav` / `mp3.toFlac` / `wav.trim` / `wav.toFlac` / `flac.trim` / `flac.decode` / `flac.toWav` は、秒で指定されたときだけ、サンプルレートを知るために先に `kiln_mp3_probe` / `kiln_wav_probe` / `kiln_flac_format` を呼ぶ(FLAC はメタデータだけを読む)。サンプル数だけの指定では、`trim`(`flac.trim` を含む)と `toWav` と `toFlac` と `flac.decode` は入力の解析が 1 回で済む(戻り値の秒は各 export が返すサンプルレートで計算する)。`kiln_mp3_decode` は、出力の大きさを決めるために中で probe してから復号するので、サンプル数だけの指定でも解析は 2 回(`kiln_flac_decode` はフレームの一覧 `kiln.flac.Index` を使い回すので 1 回)
- `startSample` / `endSample` に BigInt を渡すときは 0 以上 2^64 未満でなければ `RangeError` にする(u64 の引数で桁あふれしないように)
- サンプル位置は u64 なので、export 関数の引数・戻り値は JS では BigInt になる

### 2.4 PCM

```zig
// 形式: .u8(8bit 符号なし)/ .i16 / .i24(3 バイト詰め)/ .i32 / .f32 / .f64。リトルエンディアン、インターリーブ
kiln.pcm.toF32(.i24, bytes, samples);            // バイト列 → f32
var q: kiln.pcm.Quantizer = .init(.tpdf);        // .none なら四捨五入とクリップだけ
kiln.pcm.fromF32(.i16, samples, bytes, &q);      // f32 → バイト列
kiln.pcm.fromInt(.i24, 20, ints, bytes, &q);     // 20bit の整数(i32)→ バイト列(FLAC の復号結果)
kiln.pcm.toInt(.i24, bytes, ints);               // 整数形式のバイト列 → i32(FLAC への書き出し。u8 は 128 を引く)
kiln.pcm.convertInt(24, 16, ints, out, &q);      // ビット深度を変える(増やすなら左シフト、減らすならディザで丸める)
const v = kiln.pcm.quantizeBits(&q, 16, x);      // f64(満幅 ±1)→ 16 ビットの整数
```

- PCM は読み込んだ元の形式のまま持ち、必要なときだけ f32 と変換する(WAV → WAV などを無劣化にするため)
- 整数と浮動小数点の対応は `値 / 2^(bits - 1)`。16 / 24bit と 8bit は、整数 → f32 → 整数で元に戻る
- `fromInt` は、器のビット数が元のビット数以上なら下位に 0 を足す(左シフトする)だけなので可逆。少ないときは f64 に直してから `fromF32` と同じく丸める
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
// 区間を FLAC にする(整数の WAV はビット深度を変えなければ可逆)。r.patch(STREAMINFO)を出力の先頭に書き戻す
const r = try kiln.wav.toFlac(gpa, input, .{ .start = 44100 }, .{ .compression = 5 }, writer); // r.start / r.end / r.patch
const f = try kiln.wav.toFlacAlloc(gpa, input, .{ .start = 44100 }, .{});  // 一括版(書き戻し済み): f.data / f.start / f.end
```

- 既定の形式は 16bit 整数、ディザは TPDF(§2.4)
- 1 フレームのバイト数(チャンネル数 × サンプルのバイト数)が 65535 を超えるとき、またはサンプルレート × 1 フレームのバイト数が 32bit に収まらないときは `InvalidOptions`(`fmt ` の nBlockAlign / nAvgBytesPerSec に書けないため)
- 2 チャンネル以下は WAVE_FORMAT_PCM / IEEE_FLOAT、3 チャンネル以上は WAVE_FORMAT_EXTENSIBLE で書く(チャンネルマスクは先頭から順に割り当てる)。浮動小数点でも `fact` チャンクは書かない
- `Encoder.fileLen(options)` は、フレーム数を渡して書いたときのファイル全体のバイト数(ヘッダと詰め物を含む)を返す。4GiB を超えるなら `TooLarge`。前もって一度に確保するのに使う(`kiln.mp3.toWavAlloc`)
- フレーム数を渡すと、正しい長さのヘッダを先に書き、`finish` で書いた長さと合うかを確かめる(違えば `LengthMismatch`)。渡さないと長さを 0xFFFFFFFF にしたヘッダを書き、`finish` が正しいヘッダを返す
- 中身が奇数バイトのときの詰め物は、フレーム数を渡したときだけ書く。渡さないときは、書き戻せないパイプなどで詰め物がサンプルとして読まれないよう書かず、`finish` が返すヘッダの RIFF サイズにも含めない

### 2.6 FLAC

```zig
const info = try kiln.flac.probe(input);         // sample_rate, channels, bits_per_sample, samples, frames, md5
// デコード: 区間の PCM をインターリーブした整数(bits_per_sample ビット)で sink.writeI32 に渡す
const d = try kiln.flac.decode(gpa, input, .{ .start = 0, .end = 44100 }, &sink); // d.invalid_frames など
// WAV にする。format を省く(null)とビット深度を保つ形式
const r = try kiln.flac.toWav(gpa, input, .{ .start = 0 }, .{ .format = null, .dither = .tpdf }, writer);
const t = try kiln.flac.toWavAlloc(gpa, input, .{}, .{});   // t.data / t.result
const f = try kiln.flac.streamFormat(input);     // メタデータだけを読む(sample_rate, channels, bits_per_sample)
// フレームの一覧。区切りを探す走査を 1 回で済ませ、長さを知ってから復号するときに使う
var ix = try kiln.flac.Index.init(gpa, input);
defer ix.deinit(gpa);
const total = ix.info().samples;
_ = try ix.decode(gpa, .{ .end = total }, &sink); // ix.toWav も同じ
```

```zig
// 書き出し: ストリーミングのエンコーダ。finish が返す STREAMINFO を出力の先頭に書き戻す
var enc: kiln.flac.Encoder = try .init(gpa, writer, .{ .sample_rate = 44100, .channels = 2, .bits_per_sample = 16, .compression = 5 });
defer enc.deinit();
try enc.writeI32(interleaved);                   // writeF32 は TPDF ディザで丸めて書く(mp3.decode の sink にもなる)
const patch = try enc.finish();                  // patch.offset / patch.bytes(STREAMINFO の 34 バイト)
// 一括版(STREAMINFO を書き戻したバイト列を返す)
const a = try kiln.flac.encodePlanarAlloc(gpa, &.{ left, right }, 44100, .{ .bits_per_sample = 16 });
const m = try kiln.mp3.toFlacAlloc(gpa, mp3_input, .{ .start = 0 }, .{});  // m.data / m.result(流して書く版は mp3.toFlac)
```

- `gpa` はフレームの一覧と、復号・符号化の作業領域に使う。設計と検証は [`flac.md`](flac.md)
- 書き出しの指定は `kiln.flac.WriteOptions`(`bits_per_sample`、`compression`、`dither`)で、WAV / MP3 / PCM のどれから書くときも同じ。エラーは `OutOfMemory` / `InvalidOptions`(チャンネル数・サンプルレート・ビット深度・段階が範囲外)/ `TooLarge` / `InternalError`
- 壊れたフレームや失われたフレーム(番号の飛びから分かるもの)は無音にし、その数を `invalid_frames` で返す。`probe` の長さにも含める
- 位置はフレーム単位で、最初のフレームの先頭を 0 とする。範囲外の指定は MP3 と同じく丸める
```zig
// 切り出し(FLAC → FLAC)。r.patch(STREAMINFO)を出力の先頭に書き戻す
const r = try kiln.flac.trim(gpa, input, .{ .start = 44100, .end = 88200 }, writer); // r.start / r.end / r.invalid_frames / r.patch
const c = try kiln.flac.trimAlloc(gpa, input, .{ .start = 44100 });  // 一括版(書き戻し済み): c.data など
_ = try ix.trim(gpa, .{ .start = 44100 }, writer);  // フレームの一覧を作ってあれば、それを使い回す
```

- 切り出しは、区間に丸ごと入るフレームをコピーし、先頭と末尾にかかるフレームだけを作り直す。出力は、最後を除くフレームの長さがそろえば固定ブロック長、そうでなければ可変ブロック長(Safari が読める形にする。詳細は [`flac.md`](flac.md) §7)。1 フレームの符号化はエンコーダと共通の `FrameEncoder`(`src/flac/encoder.zig`)

## 3. Zig 0.17.1 で確認したこと

試作(16bit WAV を `*Io.Writer` に書くコア)を、テスト・CLI・`wasm32-freestanding` の 3 通りで動かして確認した。

- `main` は `pub fn main(init: std.process.Init) !void` の形(終了コードを返すなら `!u8`。K!LN の CLI は `!u8`)。`init` に `gpa` / `arena` / `io` / 引数 / 環境変数が入る。
- `std.Io.Reader` / `std.Io.Writer` はバッファを内部に持つ具体型(vtable 方式)。`Reader.fixed` / `Writer.fixed` / `Writer.Allocating` は OS なしで動き、wasm でもそのまま使える。
- ファイルは `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit)` で一括読み込み、`file.writer(io, &buf).interface` を `*Io.Writer` として書き出せる。
- wasm では `std.heap.wasm_allocator` が使える。試作の wasm は ReleaseSmall で約 3KB。
- ファズテストは `std.testing.fuzz` が使える。
- 最適化モードの型は `std.lang.Optimize` で、値は `.debug` / `.safe` / `.fast` / `.small`。以前の `std.builtin.OptimizeMode` と `.Debug` などは非推奨(0.18.0 の後に削除予定)。
- 配列の繰り返し演算子 `**` は使えない(`"ab" ** 2` は構文エラー)。0 で埋めた配列は `@splat(0)` で作る。
- CRC-16/ARC(LAME タグの CRC)は `std.hash.crc.@"CRC-16/ARC"` にある。FLAC のフレームヘッダの CRC-8(多項式 0x07、初期値 0)は `@"CRC-8/SMBUS"`、フレームの CRC-16(多項式 0x8005、初期値 0、反転なし)は `@"CRC-16/UMTS"`。
- wasm32 の export 関数が返すポインタ・長さ(usize)は、JS には符号付きの i32 として見える。2GiB 以上のアドレスや、長さ 0 の確保で `wasm_allocator` が返すダミーのアドレス(0xFFFFFFFF)が負になるため、JS 側で `>>> 0` して扱う。
- enum と整数の変換: `@typeInfo(E).@"enum"` のフィールドは `field_names` / `field_values`(`fields` はない)。範囲を確かめて整数から enum にするには `std.enums.fromInt(E, n)`(範囲外なら null)。`@enumFromInt` を書くと、`zig fmt` が `@fromBackingInt(@intCast(...))` に書き換える
- stdout / stderr は `Io.File.Writer.initStreaming` で書く。`.init` は位置指定書き込みなので、ファイルにリダイレクトすると先頭から書いてしまい、`>>` で追記しても既存の内容を上書きする(macOS で確認)。
