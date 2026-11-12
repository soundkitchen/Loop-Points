# アーキテクチャ方針

コア API の形についての方針。2026-11-09 に合意した叩き台で、細部は実装しながら詰める。

## 1. 構成

- **コア**: I/O を持たない Zig のライブラリ。ファイルや OS には触れず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う。
- **wasm**: `wasm32-freestanding` 向けの薄いラッパー。自前の export 関数(alloc / free / 各処理)に、薄い JS ラッパーを被せる。Loop Points は JS ラッパーをソースから直接 import し、wasm をバイト列で渡す。
- 当初は CLI もコアの薄いラッパーとして作ったが、2026-11-11 に外した([`draft.md`](draft.md) §2.9)。

### 1.1 ディレクトリとビルド

| パス | 内容 | ビルド成果物 |
|---|---|---|
| `src/root.zig` | コアのルート。モジュール名 `kiln`。入力の形式とサンプルレートをヘッダーから読む `kiln.detect` もここに置く | — |
| `src/pcm.zig` | PCM のサンプル形式と、f32 との変換(`kiln.pcm`) | — |
| `src/mp3.zig`, `src/mp3/` | MP3 の解析と無劣化トリム(`kiln.mp3`)。`frame`(フレームヘッダ)/ `id3` / `xing`(Xing・LAME タグ)/ `stream`(入力の解析)/ `trim` に分ける。デコーダは `bits`(ビット読み取り)/ `huffman` / `layer3`(周波数領域の処理)/ `synth`(IMDCT と合成フィルタ)/ `decoder`(設計は [`mp3-decoder.md`](mp3-decoder.md)) | — |
| `src/wav.zig`, `src/wav/` | WAV の解析とサンプル精度のトリム、エンコーダ(`kiln.wav`)。`parse`(チャンクの解析)/ `header`(ヘッダの書き出し)/ `encoder` に分ける | — |
| `src/ogg.zig`, `src/ogg/` | Ogg(Vorbis / Opus)の解析と無劣化の切り出し(`kiln.ogg`)。`page`(ページとパケットの読み出し)/ `vorbis`(識別ヘッダと設定ヘッダ、音声パケットの長さ)/ `opus`(ID ヘッダとパケットの長さ)/ `stream`(パケットを順にたどる。解析と切り出しで共有)/ `trim`(パケットを集めてページを作り直す)に分ける(設計は [`ogg.md`](ogg.md)) | — |
| `src/m4a.zig`, `src/m4a/` | m4a(MP4 コンテナの AAC / ALAC)の解析と、AAC の切り出し(`kiln.m4a`)。`box`(ボックスの読み取り)/ `asc`(AudioSpecificConfig)/ `trim`(サンプルの表の読み取りと切り出し)に分ける(設計は [`m4a.md`](m4a.md)) | — |
| `src/aac.zig` | aac(ADTS)の解析(`kiln.aac`。設計は [`aac.md`](aac.md)) | — |
| `src/flac.zig`, `src/flac/` | FLAC の解析・復号・書き出し(`kiln.flac`)。`bits`(ビットの読み書き)/ `frame`(フレームヘッダ)/ `metadata`(`fLaC` とメタデータブロック)/ `stream`(フレームの区切り)/ `decoder`(サブフレームの復号)/ `encoder`(エンコーダ)/ `lpc`(線形予測の分析)/ `trim`(FLAC → FLAC の切り出し)に分ける(設計は [`flac.md`](flac.md)) | — |
| `wasm/main.zig` | wasm の export 関数 | `zig-out/kiln.wasm` |
| `wasm/kiln.ts` | JS 側の包み(TypeScript。`load()` で wasm を読み込む)。型もここに書く。Loop Points はこのファイルを直接 import する | — |
| `wasm/test/` | kiln.ts の実行時テスト(Node の `node:test`。`*.test.mjs`)。`wasm/kiln.ts` を型を消して読み、`zig-out/kiln.wasm` を読む。`types.ts` は誤った使い方が型エラーになることの検査(実行しない) | — |
| `wasm/tsconfig.json` | kiln/wasm の型の検査の設定。Loop Points の `tsconfig.json` に `erasableSyntaxOnly`(型を消すだけで動く書き方)を足したもの | — |
| `LICENSE` | MIT の全文 | — |
| `THIRD_PARTY_NOTICES.md` | 外部から取り込んだコードや数表の出所とライセンス(方針は [`draft.md`](draft.md) §2.5) | — |
| `testdata/` | テスト用の音声(MP3、WAV、FLAC、Ogg、m4a、aac)と、それを `@embedFile` するモジュール(`testdata.zig`)。作り方は `testdata/README.md` | — |

- `zig build`(`zig build wasm` と同じ)は wasm をビルドする。wasm は `-Dtarget` に関係なく常に `wasm32-freestanding` 向けで、最適化モードが debug のときは small でビルドする
- `zig build test` はコアのテストを実行し、wasm のビルドが通ることも確かめる(wasm はネイティブで実行できないため)。Loop Points のリポジトリ直下の `npm run kiln:test` は、これに加えて kiln.ts の実行時のテストと型の検査を実行する
- コアのテストは、`testdata` モジュールを import できるテスト専用のモジュール(ルートは同じ `src/root.zig`)で実行する。wasm に入れる `kiln` モジュールには `testdata` を含めない。`src/` の各ファイルはトップレベルに `const testdata = @import("testdata");` を置き、`test` ブロックからだけ参照する(Zig はトップレベルの宣言を参照されたときにだけ解析するため、テスト以外のビルドでは import が解決されない)
- wasm とテストの各ビルドで使うコアのモジュールは、`build.zig` の `kilnModuleOptions` で同じ定義から作る。テスト用のモジュールは、それに `testdata` の import を足したもの
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

- 位置はタイムライン上のサンプル位置([`lyria-mp3.md`](lyria-mp3.md) §5.1)。秒からの変換は JS 側で行う
- 範囲外の指定はコアが丸め、実際に切り出した区間を返す。丸めたことを利用者に伝えるのは呼び出し側
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

2026-11-11 に外した([`draft.md`](draft.md) §2.9)。CLI が使っていた入力の形式の判定(`kiln.detect`)はコアに残し、2026-11-12 に、サンプルレートも返す形にして wasm と kiln.ts に出した(下の「形式とサンプルレートの判定」)。

### 2.2.1 形式とサンプルレートの判定(`kiln.detect`)

`kiln.detect(input)` は、入力のヘッダーから形式(`Format`)とデコード結果のサンプルレートを読み、`?Detected`(`format` と `sample_rate: ?u32`)を返す。Loop Points が、音源を開くたびに元のサンプルレートを知るのに使う([`draft.md`](draft.md) §2.14)。

- **形式の判定**: 拡張子は見ない。WAV は先頭のバイト列(RIFF / RF64 / RIFX と WAVE)、FLAC は先頭(ID3v2 タグがあればその後)の `fLaC` か Ogg FLAC の印、Ogg は先頭の `OggS`、m4a は先頭の `ftyp` ボックス、aac は先頭(ID3v2 タグがあればその後)に ADTS のフレームが続くことで判定し、それ以外は MPEG オーディオのフレームを探す。ADTS は MP3 と同期ワードが似ているので、MP3 より先に見る。どれでもなければ null
- **MP3 のフレームを探す範囲**: MP3 には先頭の印がなく、フレームの並び(次の位置にも同じ種類のヘッダがあること)で判定する。先頭にゴミがある MP3 も受け付けるが、解析(`mp3.probe`)が入力の終わりまで探すのと違い、最初のフレームは先頭(ID3v2 タグの後ろ)の 64KiB(`mp3.header_search_len`)の中でだけ探す。MP3 でない入力の奥(圧縮された音声のデータなど)で、偶然フレームに見える並びを拾わないため。それでも誤って MP3 と判定することはありうるので、Loop Points は、拡張子が .mp3 のときだけ MP3 の判定を使う
- **ヘッダーだけを読む**: 音声のデータはたどらない(`probe` と違い、フレームやページを走査しない)。そのため軽く、入力はファイルの先頭の一部でもよい。先頭の一部を渡して形式かレートが読めなかったときは、全体を渡すと読めることがある(大きな ID3v2 タグの後ろの MP3 や FLAC、moov が後ろにある m4a、`fmt ` が後ろにある WAV)。足りないことを知らせるエラーはなく、呼ぶ側が「レートが null なら全体を渡し直す」と決める
- **kiln が扱えない種類も読む**: 形式ごとの解析や切り出しが `UnsupportedFormat` や `Invalid…` にするものでも、ヘッダーのレートは返す(ブラウザはデコードできることがある)。詳しいエラーは各形式の解析で出す

| 形式 | レートを読む場所(各形式の `headerSampleRate`) | kiln が扱えなくても読むもの | null になるもの |
|---|---|---|---|
| WAV | `fmt ` チャンク。符号化の種類は見ず、`data` チャンクも要らない | RF64、ビッグエンディアンの RIFX、μ-law / A-law、ADPCM など | `fmt ` が入力にない、レートが 0 |
| FLAC | 最初のメタデータブロックの STREAMINFO だけ(`metadata.Metadata.streamInfo`) | 後ろのメタデータやフレームが壊れたもの | Ogg FLAC、最初のブロックが STREAMINFO でない、レートが 0 |
| Ogg | 最初のページの識別ヘッダ。Vorbis はヘッダの値、Opus は常に 48000 | 連結、多重化、壊れたページのあるもの | Vorbis でも Opus でもない(Speex など)、識別ヘッダが読めない |
| m4a | 最初の moov の、最初の音声トラックのサンプルエントリ(HE-AAC は SBR の後のレート。ALAC も読む)。サンプルの表や mdat は見ない | HE-AAC v2、断片化した MP4(解析の `findMoov` と違い、moov の後ろの moof は見ない)、サンプルの表が食い違うもの | SBR があるか分からない AAC(レートが実際の半分のことがある)、AAC でも ALAC でもないコーデック(MP4 の Opus や FLAC)、moov が入力にない、音声トラックがない |
| aac(ADTS) | 読まない | — | いつも null(ヘッダーから HE-AAC かどうかが分からない。[`aac.md`](aac.md) §3) |
| MP3 | 先頭の ID3v2 タグの後ろの、最初のフレームのヘッダ(`mp3/stream.zig` の `headerSampleRate`。フレームの確かめ方は解析と同じで、探す範囲だけ 64KiB に限る) | MPEG-2 / 2.5、Layer I / II(`AnyHeader` のレート) | フレームが見つからないときは、形式ごと null |

### 2.3 wasm と JS

- JS に返すエラーの名前は、wasm/main.zig の `KilnError`(エラーの集合)に限る。`fail` はこの集合しか受け付けないので、export が新しいエラーを返しうるようになるとコンパイルが通らなくなる。kiln.ts の `KilnErrorCode` も同じ一覧にする(この同期は手作業。両方の定義の横に、もう一方を指すコメントがある)
- `InternalError` は kiln の不具合(起きるはずのない食い違い。たとえば MP3 → WAV で書いた長さが WAV のヘッダと違う)のときに返す。止めずにエラーとして返すので、wasm のインスタンスはそのまま使い続けられる
- 型は kiln.ts の中に書き、実装と同じファイルで確かめる(2026-11-11 までは kiln.js と型定義の kiln.d.ts に分けていた。[`draft.md`](draft.md) §2.9)。入力は `ArrayBufferLike | ArrayBufferView`(バイト列として読むものすべて)、出力は `Uint8Array<ArrayBuffer>` / `Float32Array<ArrayBuffer>`(そのまま `Blob` などに渡せる)。`wav.encode` は `AudioBuffer` を構造(`AudioBufferLike`)で受け、`Float32Array[]` を渡すときは `sampleRate` が必須。wasm の export 関数の型は kiln.ts の `Exports` に手で写す(wasm/main.zig の export を変えたら合わせる)。引数の数や並びがずれても tsc は気づかず、wasm は足りない引数を 0 として黙って動くので、`wasm/test/convert.test.mjs` で mp3 / wav / flac / ogg(Opus と Vorbis の切り出し)/ m4a(AAC の切り出し)の各経路を実際に呼んで確かめる
- `load(source)` の `source` は wasm のバイト列だけで、省けない。URL からは読まない(fetch しない)。Loop Points は CSP の `connect-src 'none'` で fetch を止め、wasm をチャンクに埋め込んでバイト列で渡すため。kiln.ts に `new URL('./kiln.wasm', import.meta.url)` を書くと、Vite や webpack 5 はそれをアセットの参照とみなし、使わない kiln.wasm をビルド結果に出力する(soundkitchen/kiln#11)ので、その書き方も残さない。バイト列でない値(省いたとき、URL、`Response`、`Blob` など)は `TypeError` で reject する(`load` は async なので、投げるのではなく reject した Promise を返す)
- kiln.ts を変えたら、Loop Points のリポジトリ直下で `npm run kiln:test` を実行する。`kiln/wasm/tsconfig.json` で型を確かめ(Loop Points の `tsconfig.json` の include にも kiln/wasm があるので、`npm run build` でも確かめる)、`wasm/test/` の Node のテストで実行時の振る舞いを確かめる。Node は kiln.ts を型を消すだけで実行するので、型を消すだけで動く書き方にする(`enum`、`namespace`、コンストラクタの引数のプロパティは使わない。`erasableSyntaxOnly` で確かめる)。`wasm/test/types.ts` は、誤った使い方(`start` と `startSample` の同時指定、未知の `format`、`sampleRate` のない `Float32Array[]` など)が型エラーになることを `@ts-expect-error` で確かめる。kiln.ts の型を意図して緩めるときは、ここも直す
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
- `mp3.trim` / `mp3.decode` / `mp3.toWav` / `mp3.toFlac` / `wav.trim` / `wav.toFlac` / `flac.trim` / `flac.decode` / `flac.toWav` / `ogg.trim` / `m4a.trim` は、秒で指定されたときだけ、サンプルレートを知るために先に `kiln_mp3_probe` / `kiln_wav_probe` / `kiln_flac_format` / `kiln_ogg_probe` / `kiln_m4a_probe` を呼ぶ(FLAC はメタデータだけを読む)。サンプル数だけの指定では、`trim`(`flac.trim`、`ogg.trim`、`m4a.trim` を含む)と `toWav` と `toFlac` と `flac.decode` は入力の解析が 1 回で済む(戻り値の秒は各 export が返すサンプルレートで計算する)。`kiln_mp3_decode` は、出力の大きさを決めるために中で probe してから復号するので、サンプル数だけの指定でも解析は 2 回(`kiln_flac_decode` はフレームの一覧 `kiln.flac.Index` を使い回すので 1 回)
- `detect(bytes)` は、ヘッダーから形式とサンプルレートを読み、`{ format, sampleRate }` か null を返す(§2.2.1)。`format` は `'mp3'` / `'wav'` / `'flac'` / `'ogg'` / `'m4a'` / `'aac'`、`sampleRate` は読めなければ null。失敗はなく、`KilnError` を投げない。`kiln_detect` はいつも true を返し、`kiln_value` に 0: 形式が分かったか、1: 形式(`kiln.Format` の番号。JS 側の `DETECT_FORMATS` と並びを合わせる)、2: サンプルレート(0 は読めなかった)を置く。入力は、ほかの関数と同じく渡された分をまるごと linear memory に写すので、大きなファイルでは呼ぶ側が先頭の一部だけを渡す
- `ogg.probe` / `m4a.probe` / `aac.probe` は解析(§2.7)。Ogg と m4a は切り出しの `ogg.trim`(`kiln_ogg_trim`。Opus と Vorbis)と `m4a.trim`(`kiln_m4a_trim`。AAC)も持つ。`kiln_value` が足りないので 10 個に増やした(export は `setValues` で、使わない分は 0 にする)。SBR / PS の 3 値は 0: なし、1: あり、2: 不明でやり取りし、JS では `false` / `true` / `null` にする。`m4a.probe` は AudioSpecificConfig を出力のバイト列で返す
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

### 2.7 Ogg / m4a / aac

```zig
const o = try kiln.ogg.probe(input);  // codec(.vorbis / .opus), sample_rate, input_sample_rate, channels, samples, pre_skip, invalid_pages,
                                      // trimmable(ogg.trim で切り出せるか)
const m = try kiln.m4a.probe(input);  // codec(.aac / .alac), object_type, sbr, ps, sample_rate, channels, bits_per_sample,
                                      // samples, encoder_delay, audio_specific_config, trimmable(m4a.trim で切り出せるか)
const a = try kiln.aac.probe(input);  // profile, mpeg_version, sample_rate, channels, frames, samples(ヘッダの値)
// Opus / Vorbis を再エンコードせずに切り出す(位置は再生位置のサンプル数。Opus は 48kHz)。trimAlloc は一括版。
// Vorbis の r.start は、パケットの区切りに寄せた実際の切り始め(指定以下)
const r = try kiln.ogg.trim(gpa, input, .{ .start = 48000, .end = 96000 }, writer);  // r.start / r.end / r.sample_rate
// m4a の AAC を再エンコードせずに切り出す(位置はデコード結果のレートのサンプル数。HE-AAC は 2 サンプル単位に寄せ、
// q.start / q.end が実際の区間)
const q = try kiln.m4a.trim(gpa, input, .{ .start = 44100, .end = 88200 }, writer);
```

- `probe` はアロケータを使わず、入力全体の `[]const u8` を受け取る。切り出しは Ogg の Opus と Vorbis、m4a の AAC(aac(ADTS)はまだ。[`draft.md`](draft.md) §2.10〜§2.12)。`ogg.trim` はパケットの一覧とページの組み立てに、`m4a.trim` はサンプルの表と moov の組み立てにアロケータを使う。方式は [`ogg.md`](ogg.md) §6(Opus)、§7(Vorbis)、[`m4a.md`](m4a.md) §5(AAC)
- 長さ(`samples`)は再生される長さ。Ogg は先頭と末尾の切り詰め(Opus の pre-skip を含む)、m4a は編集リストか iTunSMPB の遅延と詰め物を除く。aac(ADTS)には書く場所がないので含む
- サンプルレートとチャンネル数はデコード結果のもの(Opus は 48kHz、HE-AAC は SBR / PS の後)。ただし aac(ADTS)はヘッダの値で、HE-AAC かどうかは分からない(音声データを読まないため。[`aac.md`](aac.md) §3)。m4a でもファイルから分からなければ `sbr` / `ps` が null
- JS は `ogg.probe` / `ogg.trim` / `m4a.probe` / `m4a.trim` / `aac.probe`。`ogg.trim` と `m4a.trim` は `mp3.trim` と同じ形で、`kiln_ogg_trim` と `kiln_m4a_trim` の `kiln_value` は 0: start、1: end、2: サンプルレート。`aac.probe` の `sbr` は常に null。`m4a.probe` の `audioSpecificConfig` は WebCodecs の `AudioDecoder` の `description` に使える
- 設計と検証は [`ogg.md`](ogg.md) / [`m4a.md`](m4a.md) / [`aac.md`](aac.md)

## 3. Zig 0.17.1 で確認したこと

試作(16bit WAV を `*Io.Writer` に書くコア)を、テスト・CLI・`wasm32-freestanding` の 3 通りで動かして確認した。

- `main` は `pub fn main(init: std.process.Init) !void` の形(終了コードを返すなら `!u8`)。`init` に `gpa` / `arena` / `io` / 引数 / 環境変数が入る。
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
