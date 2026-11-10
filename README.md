# K!LN

音声を読み込み、クロップして、任意の形式で書き出すための Zig 製ライブラリです。CLI とブラウザ(wasm)の両方で動かすことを目指しています。

最初の到達点は、Google Gemini Lyria が出力する MP3 を、再エンコードせずにサンプル精度でトリムすることです。今のところ、MP3(MPEG-1 Layer III)と WAV(PCM・浮動小数点)を、形式を変えずにサンプル精度で切り出せます。FLAC も FLAC のまま可逆に切り出せます。MP3 と FLAC をデコードして WAV に、WAV と MP3 を FLAC に書き出すこともできます。Ogg(Vorbis / Opus)・m4a(AAC / ALAC)・aac(ADTS)は、今のところサンプルレートや長さを調べる(probe)だけです。

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

JS ラッパー(`kiln.js`)を変えたときは、Node 22 以降で実行時のテストを、TypeScript 5.7 以降で型定義の検査を動かします(どちらも `zig build` には含めません)。

```sh
zig build && node --test 'wasm/test/*.test.mjs'
npx -p typescript tsc -p wasm/types/tsconfig.dom.json   # worker / es も同じ
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
kiln trim in.wav out.flac --format flac                 # WAV を FLAC に(可逆。既定は flac -5 と同じ圧縮)
kiln trim in.mp3 out.flac --format flac --compression 8 --bits 24
kiln trim in.flac out.flac --start 10 --end 20           # FLAC のまま切り出す(可逆。境目のフレームだけ作り直す)
kiln info in.m4a                                         # 形式・サンプルレート・チャンネル数・長さを表示する
```

- 出力の形式は `--format mp3|wav|flac` で指定できます(省くと入力と同じ)。変換できるのは MP3 / FLAC → WAV と WAV / MP3 → FLAC です
- FLAC → FLAC は、区間に丸ごと入るフレームをそのままコピーし、先頭と末尾にかかるフレームだけを作り直します(復号すると元の区間と同じ PCM)。タグと画像は残し、シークテーブル・CUE シート・PADDING は捨てます。Chrome / Firefox / Safari の `decodeAudioData` でも、サンプル単位で元と一致します([`docs/flac.md`](docs/flac.md) §7)
- WAV / MP3 からの FLAC の書き出しは `--compression 0〜8`(flac コマンドの -0〜-8 と同じ。既定は 5)と `--bits 4〜32`(既定は整数の WAV なら元のビット深度、それ以外は 16)で調整できます。大きさは flac コマンドの同じ段階とほぼ同じ(±0.3% 程度)です([`docs/flac.md`](docs/flac.md) §6)
- MP3 / FLAC → WAV の書き出しは `--sample-format u8|i16|i24|i32|f32|f64` と `--dither tpdf|none` で調整できます。FLAC の既定はビット深度を保つ形式で、元の PCM のまま書き出します(libFLAC・ffmpeg と一致。[`docs/flac.md`](docs/flac.md))。MP3 のデコーダは ffmpeg の float デコーダと長さが一致し、値の差は 5e-6 以内です([`docs/mp3-decoder.md`](docs/mp3-decoder.md))
- WAV は `data` の中身を切り出すだけなので、元の形式のまま無劣化です
- `kiln info` は MP3 / WAV / FLAC / Ogg / m4a / aac の情報を表示します。Ogg / m4a / aac はまだ切り出せません。長さは再生される長さで、Opus の pre-skip や m4a の先頭の遅延(編集リストか iTunSMPB)を除きます。aac(ADTS)はヘッダだけでは HE-AAC かどうか分からないため、そのことを注意書きします([`docs/aac.md`](docs/aac.md) §3)

- 再エンコードせずに切り出します。ffmpeg でデコードすると、元ファイルの該当区間とサンプル単位で一致します。Chrome / Firefox / Safari の `decodeAudioData`、mpg123、macOS の CoreAudio でも、位置と長さは同じで、違いはデコーダごとの丸めの差だけです。`<audio>` 要素では、Chrome / Firefox はサンプル単位で正確、Safari は長さと末尾が正確で、再生開始直後(数十 ms)は確かめられていません(方式と検証結果は [`docs/lyria-mp3.md`](docs/lyria-mp3.md))
- Safari などは、LAME タグのない元ファイル(Lyria の出力など)を ffmpeg より 529 サンプル(約 12ms)前にずらして再生します。そうしたプレーヤーで元ファイルを聴きながら位置を選ぶと、その分ずれます
- 位置は ffmpeg でデコードしたときの先頭を 0 とします。MP3 → MP3 の無劣化トリムでは、LAME タグのない MP3(Lyria の出力など)の先頭 529 サンプルより前からは切り出せません(指定すると 529 に切り上げます)。MP3 → WAV / FLAC(`--format wav` / `--format flac`、JS の `mp3.decode` / `mp3.toWav` / `mp3.toFlac`)はデコードするので切り上げず、0 から書き出せます
- 入力の ID3v2 タグ(Lyria の C2PA マニフェストを含む)は引き継ぎません

### ブラウザ(wasm)

`zig build` で `zig-out/wasm/` にできる `kiln.wasm` と `kiln.js` を同じ場所に置いて使います。TypeScript の型定義 `kiln.d.ts`(TypeScript 5.7 以降)も同じ場所にできます。配布するときは、同じディレクトリにある `LICENSE` も一緒に置いてください(MIT の著作権表示)。

```js
import { load } from './kiln.js';

const kiln = await load(new URL('./kiln.wasm', import.meta.url));
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

// FLAC に書き出す(compression は 0〜8、既定は 5。bitsPerSample の既定は 16)
const flacFile = kiln.flac.encode(audioBuffer, { compression: 8 });
const { data: flacOfWav } = kiln.wav.toFlac(wavBytes, { start: 0.5, end: 3 }); // 整数の WAV は可逆
const { data: flacOfMp3 } = kiln.mp3.toFlac(bytes, { start: 1.5, end: 10 });
const { data: flacCut } = kiln.flac.trim(flacBytes, { start: 1.5, end: 10 });   // FLAC のまま切り出す(可逆)

// Ogg / m4a / aac は今のところ解析だけ。サンプルレートはデコード結果のもの(Opus は 48000)
const oggInfo = kiln.ogg.probe(oggBytes);      // { codec: 'opus' | 'vorbis', sampleRate, inputSampleRate, samples, preSkip, ... }
const m4aInfo = kiln.m4a.probe(m4aBytes);      // { codec: 'aac' | 'alac', profile, sbr, ps, sampleRate, samples, encoderDelay, ... }
const aacInfo = kiln.aac.probe(aacBytes);      // ADTS のヘッダの値。sbr は常に null(HE-AAC ならレートは 2 倍)
```

- 失敗すると `KilnError` を投げます。`code` はエラーの名前(`'NotMp3'` / `'EmptyRange'` など。一覧は `kiln.d.ts` の `KilnErrorCode`)
- 処理は同期です。何分もある曲のデコードには数百 ms かかるので、メインスレッドを止めたくなければ Worker で動かしてください
- `load` には wasm の URL(fetch します)かバイト列を必ず渡します。URL は、`load` を呼ぶモジュールから見た `kiln.wasm` の位置です(上の例は、呼ぶモジュールと `kiln.js`・`kiln.wasm` が同じ場所にある場合)。省いたときや、`Response`・`Blob` などを渡したときは、`TypeError` で reject します。既定の読み込み先は持ちません。`new URL('./kiln.wasm', import.meta.url)` を kiln.js の中に書くと、バイト列で読み込むときにも、Vite などのバンドラが使わない `kiln.wasm` をビルド結果に出力してしまうためです

**fetch を使わずに読み込む**: CSP で `connect-src` を禁じているときなどは、URL の代わりに wasm のバイト列を渡します。wasm のインスタンス化には、CSP の `script-src` に `'wasm-unsafe-eval'` が要ります。

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
const kiln = load(new URL('./kiln.wasm', import.meta.url)); // kiln-worker.js から見た位置。バイト列でもよい
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
| `testdata/` | テスト用の音声(lame で作った短い MP3、Python で書いた短い WAV、flac で作った短い FLAC、opusenc・oggenc・ffmpeg・afconvert で作った短い Ogg・m4a・aac。Lyria の実ファイルは入れない)。作り方は [`testdata/README.md`](testdata/README.md) |
| `docs/` | 設計と調査の記録。仕様として扱う |

## ドキュメント

- [`docs/draft.md`](docs/draft.md): 構想と決定事項
- [`docs/architecture.md`](docs/architecture.md): アーキテクチャ方針
- [`docs/lyria-mp3.md`](docs/lyria-mp3.md): Lyria 出力 MP3 の調査と無劣化トリム方式
- [`docs/mp3-decoder.md`](docs/mp3-decoder.md): MP3 デコーダの設計と検証
- [`docs/flac.md`](docs/flac.md): FLAC の設計と検証
- [`docs/ogg.md`](docs/ogg.md) / [`docs/m4a.md`](docs/m4a.md) / [`docs/aac.md`](docs/aac.md): Ogg・m4a・aac の解析の設計と検証

## ライセンス

MIT ライセンスです。全文は [`LICENSE`](LICENSE) を参照してください。

外部から取り込んだコードや数表は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) に記録しています。取り込んでよいライセンスなどの方針は [`docs/draft.md`](docs/draft.md) §2.5 にあります。
