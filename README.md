# K!LN

音声を読み込み、クロップして、任意の形式で書き出すための Zig 製ライブラリです。CLI とブラウザ(wasm)の両方で動かすことを目指しています。

最初の到達点は、Google Gemini Lyria が出力する MP3 を、再エンコードせずにサンプル精度でトリムすることです。今のところ、MP3(MPEG-1 Layer III)と WAV(PCM・浮動小数点)を、形式を変えずにサンプル精度で切り出せます。MP3 と FLAC をデコードして WAV に書き出すこともできます(FLAC の書き出しはこれから)。

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
kiln trim in.wav out.wav --start 0.5 --end 3        # WAV も同じ。形式は中身から判定する
kiln trim in.mp3 out.wav --format wav               # MP3 をデコードして WAV に(既定は 16bit、TPDF ディザ)
kiln trim in.mp3 out.wav --format wav --sample-format f32 --start 10 --end 20
kiln trim in.flac out.wav --format wav --start 10       # FLAC をデコードして WAV に(ビット深度を保つ)
```

- 出力の形式は `--format mp3|wav|flac` で指定できます(省くと入力と同じ)。変換できるのは MP3 / FLAC → WAV だけで、FLAC はまだ書き出せません
- MP3 / FLAC → WAV の書き出しは `--sample-format u8|i16|i24|i32|f32|f64` と `--dither tpdf|none` で調整できます。FLAC の既定はビット深度を保つ形式で、元の PCM のまま書き出します(libFLAC・ffmpeg と一致。[`docs/flac.md`](docs/flac.md))。MP3 のデコーダは ffmpeg の float デコーダと長さが一致し、値の差は 5e-6 以内です([`docs/mp3-decoder.md`](docs/mp3-decoder.md))
- WAV は `data` の中身を切り出すだけなので、元の形式のまま無劣化です

- 再エンコードせずに切り出します。ffmpeg でデコードすると、元ファイルの該当区間とサンプル単位で一致します。Chrome / Firefox / Safari の `decodeAudioData`、mpg123、macOS の CoreAudio でも、位置と長さは同じで、違いはデコーダごとの丸めの差だけです。`<audio>` 要素では、Chrome / Firefox はサンプル単位で正確、Safari は長さと末尾が正確で、再生開始直後(数十 ms)は確かめられていません(方式と検証結果は [`docs/lyria-mp3.md`](docs/lyria-mp3.md))
- Safari などは、LAME タグのない元ファイル(Lyria の出力など)を ffmpeg より 529 サンプル(約 12ms)前にずらして再生します。そうしたプレーヤーで元ファイルを聴きながら位置を選ぶと、その分ずれます
- 位置は ffmpeg でデコードしたときの先頭を 0 とします。MP3 → MP3 の無劣化トリムでは、LAME タグのない MP3(Lyria の出力など)の先頭 529 サンプルより前からは切り出せません(指定すると 529 に切り上げます)。MP3 → WAV(`--format wav`、JS の `mp3.decode` / `mp3.toWav`)はデコードするので切り上げず、0 から書き出せます
- 入力の ID3v2 タグ(Lyria の C2PA マニフェストを含む)は引き継ぎません

### ブラウザ(wasm)

`zig build` で `zig-out/wasm/` にできる `kiln.wasm` と `kiln.js` を同じ場所に置いて使います。TypeScript の型定義 `kiln.d.ts`(TypeScript 5.7 以降)も同じ場所にできます。配布するときは、同じディレクトリにある `LICENSE` も一緒に置いてください(MIT の著作権表示)。

```js
import { load } from './kiln.js';

const kiln = await load();
const bytes = new Uint8Array(await file.arrayBuffer());
const info = kiln.mp3.probe(bytes);                 // { sampleRate, channels, samples, duration, ... }
const { data } = kiln.mp3.trim(bytes, { start: 1.5, end: 10 }); // 秒。startSample / endSample でサンプル数も可
const blob = new Blob([data], { type: 'audio/mpeg' });

// WAV の切り出しも同じ形。decodeAudioData の結果を WAV にすることもできる
const wav = kiln.wav.trim(wavBytes, { start: 0.5, end: 3 }).data;
const audioBuffer = await new AudioContext().decodeAudioData(await file.arrayBuffer());
const wavFile = kiln.wav.encode(audioBuffer, { format: 'i16' }); // 既定は 16bit、TPDF ディザ

// MP3 をデコードする(ffmpeg と同じ位置で数える。decodeAudioData のようにブラウザで位置がずれない)
const { channels, sampleRate } = kiln.mp3.decode(bytes, { start: 1.5, end: 10 }); // Float32Array[]
const { data: wavOfMp3 } = kiln.mp3.toWav(bytes, { start: 1.5, end: 10, format: 'i16' });

// FLAC も同じ形。toWav の format を省くとビット深度を保つ(元の PCM のまま)
const flacInfo = kiln.flac.probe(flacBytes);           // { sampleRate, channels, bitsPerSample, samples, ... }
const { data: wavOfFlac } = kiln.flac.toWav(flacBytes, { start: 1.5, end: 10 });
```

- 失敗すると `KilnError` を投げます。`code` はエラーの名前(`'NotMp3'` / `'EmptyRange'` など。一覧は `kiln.d.ts` の `KilnErrorCode`)
- 処理は同期です。何分もある曲のデコードには数百 ms かかるので、メインスレッドを止めたくなければ Worker で動かしてください

**fetch を使わずに読み込む**: `load()` は既定で `kiln.wasm` を fetch します。CSP で `connect-src` を禁じているときなどは、wasm のバイト列を渡します。wasm のインスタンス化には、CSP の `script-src` に `'wasm-unsafe-eval'` が要ります。

```js
// Vite なら ?inline で wasm を JS に埋め込める(base64 の data URL になる)
import wasmUrl from './kiln.wasm?inline';
const b64 = wasmUrl.slice(wasmUrl.indexOf(',') + 1);
const kiln = await load(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
```

**Worker で使う**:

```js
// kiln-worker.js(new Worker(new URL('./kiln-worker.js', import.meta.url), { type: 'module' }) で起動)
import { load, KilnError } from './kiln.js';
const kiln = load(/* wasm の URL かバイト列 */);
self.onmessage = async ({ data: { bytes, start, end } }) => {
  try {
    const { data } = (await kiln).mp3.trim(bytes, { start, end });
    self.postMessage({ data }, [data.buffer]); // バイト列は転送してコピーを避ける
  } catch (e) {
    // 失敗も返す(返さないと、返事を待つメインスレッドが止まったままになる)
    self.postMessage({ error: e instanceof KilnError ? e.code : String(e) });
  }
};
```

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `src/` | コア。I/O を持たず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う |
| `cli/` | CLI。ファイルの読み書きと引数処理だけを担う薄いラッパー |
| `wasm/` | wasm 向けの export 関数(`main.zig`)、JS ラッパー(`kiln.js`)とその型定義(`kiln.d.ts`) |
| `testdata/` | テスト用の音声(lame で作った短い MP3、Python で書いた短い WAV、flac で作った短い FLAC。Lyria の実ファイルは入れない)。作り方は [`testdata/README.md`](testdata/README.md) |
| `docs/` | 設計と調査の記録。仕様として扱う |

## ドキュメント

- [`docs/draft.md`](docs/draft.md): 構想と決定事項
- [`docs/architecture.md`](docs/architecture.md): アーキテクチャ方針
- [`docs/lyria-mp3.md`](docs/lyria-mp3.md): Lyria 出力 MP3 の調査と無劣化トリム方式
- [`docs/mp3-decoder.md`](docs/mp3-decoder.md): MP3 デコーダの設計と検証
- [`docs/flac.md`](docs/flac.md): FLAC の設計と検証

## ライセンス

MIT ライセンスです。全文は [`LICENSE`](LICENSE) を参照してください。

外部から取り込んだコードや数表は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) に記録しています。取り込んでよいライセンスなどの方針は [`docs/draft.md`](docs/draft.md) §2.5 にあります。
