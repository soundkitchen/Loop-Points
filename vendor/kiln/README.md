# kiln(取り込んだビルド済みのファイル)

クロップの書き出しに使う [kiln](https://github.com/soundkitchen/kiln)(MIT)の、ビルド済みのファイルです。手で書き換えず、kiln でビルドしたものをそのままコピーします。

| 項目 | 内容 |
|---|---|
| kiln のコミット | `701c7e5aceb7999d8f654543d53ebbd6e820bdcc`(kiln の PR #9 のマージ) |
| ビルド | kiln のリポジトリで `zig build` を実行すると、`zig-out/wasm/` にできる。wasm は ReleaseSmall |

| ファイル | sha256 |
|---|---|
| `kiln.wasm` | `656f099e9823c0f393b75e791b2c9ef207de1d5ba4bbe9fafb5d2e7ccd14bf93` |
| `kiln.js` | `36647e63b1b8ca5cf72cc882723c872f7e6e94695c513dafcda6024e4f326339` |
| `kiln.d.ts` | `ade6ba32edc239db7409cd8c696ea67f49432c2c728ea9bfc93a6b164d993094` |
| `LICENSE` | `756d1efe8be4c9163a986dc6a8557e33809456d333d4b68ee760a2194ba1f279` |

## 使い方

- 読み込むのは `src/cropRender.ts` だけです。書き出すときに動的に import するので、ページを開いただけでは読み込みません
- `kiln.wasm` は、Vite の `?url&inline` で JS のチャンクに埋め込み、バイト列で `load()` に渡します。CSP の `connect-src 'none'` では、fetch で wasm を読めない(data: URL も止まる)ためです。wasm を動かすために、CSP の `script-src` に `'wasm-unsafe-eval'` を許可しています
- `kiln.js` の既定の読み込み先(`new URL('./kiln.wasm', import.meta.url)`)を Vite が見つけるので、`dist/assets/` にも `kiln-*.wasm` が出ます。使いませんが害はないので、そのままにしています

## 更新の手順

1. kiln のリポジトリで目的のコミットを取り出し、`zig build` を実行する
2. `zig-out/wasm/` の `kiln.wasm`、`kiln.js`、`kiln.d.ts`、`LICENSE` を、このフォルダにコピーする
3. この README のコミットと sha256 を書き換える
4. `npm run build` で型チェックを通し、クロップの書き出しを確かめる

足りない機能があれば、Loop Points の側で別のライブラリを足さず、kiln に Issue を立てます。
