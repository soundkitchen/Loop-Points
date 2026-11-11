# K!LN

Loop Points のクロップの書き出しを受け持つ、Zig 製のライブラリです。wasm にしてブラウザの中で動かし、音声を読み込み、切り出し、形式を選んで書き出します。ブラウザでできること(デコードなど)はブラウザで行い、できない部分(元の形式のままの切り出し、元のサンプルレートの読み取り、ブラウザにないエンコーダなど)を受け持ちます。

- 表示名は `K!LN`、識別子(ディレクトリ名・モジュール名)は `kiln` です
- もとは [soundkitchen/kiln](https://github.com/soundkitchen/kiln) で開発していて、`1eebfb7` までの履歴を `git subtree` で取り込んであります。そのため、取り込む前のコミットメッセージにある `#番号` は、soundkitchen/kiln の Issue と PR を指します

## できること

- MP3(MPEG-1 Layer III)と WAV(PCM・浮動小数点)を、形式を変えずにサンプル精度で切り出す
- FLAC を FLAC のまま可逆に切り出す
- MP3 と FLAC をデコードして WAV に、WAV と MP3 を FLAC に書き出す。`AudioBuffer` などの PCM を WAV や FLAC にする
- Ogg の Opus を Opus のまま、サンプル単位で切り出す(パケットをコピーし、pre-skip とグラニュール位置で前後の余分を捨てさせる)
- Ogg の Vorbis を Vorbis のまま切り出す(パケットをコピーし、末尾はグラニュール位置でサンプル単位に。先頭はパケットの区切りに寄せる)
- m4a の AAC を AAC のまま、サンプル単位で切り出す(フレームをコピーし、編集リストと iTunSMPB で前後の余分を捨てさせる。ALAC と HE-AAC v2 は扱わない)
- Ogg(Vorbis / Opus)・m4a(AAC / ALAC)・aac(ADTS)のサンプルレートや長さを調べる(probe)。aac(ADTS)の切り出しはまだです

## ビルドとテスト

Zig 0.17.1 を使います。手元では、Loop Points のリポジトリ直下の `.envrc`(direnv)で `~/Zig/0.17` を PATH に通します(初回は `direnv allow`)。PATH に Zig がなければ、`scripts/kiln.mjs` が公式のアーカイブを `.zig/` に取ってきて使います。

Loop Points のリポジトリ直下で実行します。

```sh
npm run kiln:build   # zig-out/kiln.wasm をビルドする(npm run dev / build の前にも動く)
npm run kiln:test    # Zig のテスト、kiln.ts の実行時のテスト、型の検査(kiln/wasm/tsconfig.json)
```

`kiln/` で Zig を直接使うこともできます。

```sh
zig build            # wasm をビルドする(zig build wasm と同じ)
zig build test       # コアのテスト(wasm のビルドも含む)
```

## Loop Points からの使い方

Loop Points は JS 側の包みの `wasm/kiln.ts`(TypeScript)をソースから直接 import し、`zig-out/kiln.wasm` を Vite の `?url&inline` でチャンクに埋め込んで、バイト列で `load` に渡します(`src/cropRender.ts`)。CSP の `connect-src 'none'` で fetch を止めているので、`load` は URL を受け取らず、バイト列だけを受け取ります。wasm を動かすには、CSP の `script-src` に `'wasm-unsafe-eval'` が要ります。

```js
import { load, KilnError } from '../kiln/wasm/kiln';

const kiln = await load(wasmBytes);                         // Uint8Array か ArrayBuffer
const bytes = new Uint8Array(await file.arrayBuffer());
const info = kiln.mp3.probe(bytes);                         // { sampleRate, channels, samples, duration, minStart, ... }
const { data, start } = kiln.mp3.trim(bytes, { start: 1.5, end: 10 }); // 秒。startSample / endSample でサンプル数も可
const wav = kiln.wav.trim(wavBytes, { startSample: 0, endSample: 44100 }).data;
const { data: wavOfMp3 } = kiln.mp3.toWav(bytes, { start: 1.5, end: 10, format: 'i16' });
const { data: flacCut } = kiln.flac.trim(flacBytes, { start: 1.5, end: 10 });   // FLAC のまま切り出す(可逆)
const { data: wavOfFlac } = kiln.flac.toWav(flacBytes, { start: 1.5, end: 10 }); // format を省くとビット深度を保つ
const pcmWav = kiln.wav.encode(audioBuffer, { format: 'i16' });                  // 既定は 16bit、TPDF ディザ
const pcmFlac = kiln.flac.encode(audioBuffer, { compression: 8 });
const oggInfo = kiln.ogg.probe(oggBytes);                   // Opus のサンプルレートは 48000。元のレートは inputSampleRate
const { data: opusCut } = kiln.ogg.trim(opusBytes, { start: 1.5, end: 10 }); // Opus / Vorbis のまま切り出す(Vorbis の start は区切りに寄せた位置)
const { data: aacCut } = kiln.m4a.trim(m4aBytes, { start: 1.5, end: 10 });    // AAC のまま切り出す(m4a.probe の trimmable が true のもの)
```

- 失敗すると `KilnError` を投げます。`code` はエラーの名前(`'NotMp3'` / `'EmptyRange'` など。一覧は `kiln.ts` の `KilnErrorCode`)
- 切り出しは範囲外の指定を丸め、実際に切り出した区間(`start` / `end` など)を返します。MP3 → MP3 の無劣化の切り出しでは、LAME タグのない MP3 の先頭 529 サンプルより前からは切り出せません(`probe` の `minStart`)
- 処理は同期です。何分もある曲のデコードには数百 ms かかります
- API の全体と型は `wasm/kiln.ts`、細部は [`docs/architecture.md`](docs/architecture.md) §2.3 にあります

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `src/` | コア。I/O を持たず、アロケータとバイト列/サンプル列、`std.Io.Reader` / `std.Io.Writer` だけを扱う |
| `wasm/` | wasm 向けの export 関数(`main.zig`)、JS 側の包み(`kiln.ts`。型つき)、型の検査の設定(`tsconfig.json`)、テスト(`test/`。実行時のテストと、誤った使い方が型エラーになることの検査) |
| `testdata/` | テスト用の音声(lame で作った短い MP3、Python で書いた短い WAV、flac で作った短い FLAC、opusenc・oggenc・ffmpeg・afconvert で作った短い Ogg・m4a・aac)。作り方は [`testdata/README.md`](testdata/README.md) |
| `docs/` | 設計と検証の記録。仕様として扱う |

## ドキュメント

- [`docs/draft.md`](docs/draft.md): 目的と決定事項
- [`docs/architecture.md`](docs/architecture.md): アーキテクチャ方針
- [`docs/lyria-mp3.md`](docs/lyria-mp3.md): Lyria 出力 MP3 の調査と、MP3 の無劣化トリムの方式
- [`docs/mp3-decoder.md`](docs/mp3-decoder.md): MP3 デコーダの設計と検証
- [`docs/flac.md`](docs/flac.md): FLAC の設計と検証
- [`docs/ogg.md`](docs/ogg.md) / [`docs/m4a.md`](docs/m4a.md) / [`docs/aac.md`](docs/aac.md): Ogg・m4a・aac の解析と、Opus・Vorbis・AAC の切り出しの設計と検証

検証の記録には、2026-11-11 に外した CLI(`kiln trim`)を使って確かめたものがあります。

## ライセンス

MIT ライセンスです。全文は [`LICENSE`](LICENSE) を参照してください。

外部から取り込んだコードや数表は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) に記録しています。取り込んでよいライセンスなどの方針は [`docs/draft.md`](docs/draft.md) §2.5 にあります。
