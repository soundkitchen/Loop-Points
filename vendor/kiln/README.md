# kiln(取り込んだビルド済みのファイル)

クロップの書き出しに使う [kiln](https://github.com/soundkitchen/kiln)(MIT)の、ビルド済みのファイルです。手で書き換えず、kiln でビルドしたものをそのままコピーします。

| 項目 | 内容 |
|---|---|
| kiln のコミット | `128a2ad0378a078a83aa2f5ee857d9b1bc7f3b34`(kiln の PR #14 のマージ) |
| ビルド | kiln のリポジトリで `zig build` を実行すると、`zig-out/wasm/` にできる。wasm は ReleaseSmall |

| ファイル | sha256 |
|---|---|
| `kiln.wasm` | `c50eeab19270a0ec55b69f97ac04d709730bcdc805b08eb674b3099e7e28c8af` |
| `kiln.js` | `ad475ea49f0289285ff6767385e6e3c4c837ae659feb1ad721805b0dae4d06c6` |
| `kiln.d.ts` | `65f69ca26f99f8341a79a755b6302bee84333904fc40fa5a25a4feb4e8c91100` |
| `LICENSE` | `756d1efe8be4c9163a986dc6a8557e33809456d333d4b68ee760a2194ba1f279` |

## 使い方

- 読み込むのは `src/cropRender.ts` だけです。クロップモードに切り替えたときに動的に import するので、ループモードだけを使う間は読み込みません
- `kiln.wasm` は、Vite の `?url&inline` で JS のチャンクに埋め込み、バイト列で `load()` に渡します。CSP の `connect-src 'none'` では、fetch で wasm を読めない(data: URL も止まる)ためです。wasm を動かすために、CSP の `script-src` に `'wasm-unsafe-eval'` を許可しています

## 更新の手順

1. kiln のリポジトリで目的のコミットを取り出し、`zig build` を実行する
2. `zig-out/wasm/` の `kiln.wasm`、`kiln.js`、`kiln.d.ts`、`LICENSE` を、このフォルダにコピーする
3. この README のコミットと sha256 を書き換える
4. `npm run build` で型チェックを通し、クロップの書き出しを確かめる
5. `dist/assets/` に `.wasm` のファイルがないことを確かめる。kiln.wasm はクロップのチャンクに埋め込むので、別のファイルとして出るなら、`kiln.js` が既定の読み込み先(`new URL('./kiln.wasm', import.meta.url)` など)を持っている

足りない機能があれば、Loop Points の側で別のライブラリを足さず、kiln に Issue を立てます。
