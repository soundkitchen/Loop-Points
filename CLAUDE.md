# Loop Points

音源のループポイント(ループする区間の開始と終了)を波形を見ながら決め、JSON に書き出す web ツール。音源の前後を切り落として書き出すクロップもできる。ゲーム開発中に作ったプロトタイプを汎用化したもので、機能と使い方は `README.md` にまとめている。

## 決定事項

| 項目 | 内容 |
|---|---|
| 名前 | 画面タイトルは `Loop Points`、GitHub リポジトリは `Loop-Points`、`package.json` の `name` と Cloudflare の Worker 名は `loop-points` |
| 処理の場所 | ブラウザ内で完結させる。音源はアップロードしない |
| デプロイ先 | Cloudflare(Workers の静的アセット)。アカウントは `Privates` で、`wrangler.jsonc` の `account_id` に書く。公開 URL は https://loop-points.soundkitchen.workers.dev/ で、誰でも開ける。`public/_headers` で CSP を付ける |
| デプロイの方法 | `main` への push のたびに Workers Builds が自動でデプロイするので、マージがデプロイの判断になる。マージ前のビルドの確認はない。失敗しても公開版は前のバージョンのままで、失敗はダッシュボードの Deployments タブのビルド履歴で確認する。手動のデプロイ(`npm run deploy`)はユーザーの指示を受けてから `main` で行う |
| Workers Builds の設定 | ダッシュボードにあり、リポジトリには残らない。ブランチは `main`、ビルドコマンドは `npm run build`(`wrangler.jsonc` には `build` を書かない。書くと `wrangler deploy` がもう一度ビルドする)、デプロイコマンドは `npx wrangler deploy`、パスは `/`、プレビュービルドとビルドキャッシュはオフ、Build watch paths は既定(すべて)。`npm run build` は `prebuild` で kiln の wasm もビルドする(Zig は下の「Zig」の行) |
| Node | `^24.22.1 \|\| >=26.12.1`。それぞれのセキュリティ更新を適用したバージョン以降とし、`package.json` の `engines` に書く。Workers Builds のビルドは `.node-version` で固定し、セキュリティ更新に合わせて上げる |
| Zig | 0.17.1。kiln の wasm のビルドに使う。手元は direnv(リポジトリ直下の `.envrc`)で `$HOME/Zig/0.17` を PATH に通す。PATH にないとき(Workers Builds)は、`scripts/kiln.mjs` が公式のアーカイブを `.zig/` に取ってきて、sha256 を確かめてから使う。取ってくる先は、Zig の求めるとおりコミュニティのミラーを順に試し、最後に ziglang.org にする。展開は `tar` で、できなければ Python の `tarfile` で行い、展開し終えてから `.zig/` の中の名前に移す。バージョンを上げるときは、`scripts/kiln.mjs` のバージョンと sha256、`kiln/build.zig.zon` の `minimum_zig_version` を一緒に直す |
| 対象ユーザー | 自分やチーム |
| 対象ブラウザ | File System Access API のある Chromium 系(Chrome、Edge など)に絞る。ない環境(Firefox、Safari、iPhone と iPad など)では、`src/entry.ts` で判定して案内を出して止め、本体を読み込まない。本体が動くまでは操作の部分を隠し、本体を読み込めなければ再読み込みを促す。この API は HTTPS か `localhost` でしか使えない。ダウンロードでは保存時にブラウザが名前を変えてもページから分からず、成否も判定できないため(#9) |
| 音源を開く前の画面 | 音源を開くまでは、編集画面とヘッダーのボタンを隠し、ドロップ先の枠に「音源を開く」「JSON を読み込む」のボタンを置いた案内を出す。ヘッダーにはタイトルと配色の切り替えだけを残す。音源より先に JSON を読み込んだときは、案内に JSON の名前と項目の数を出す。音源を開くと編集画面に切り替える |
| JSON の形式 | ファイル名ごとの `loopStart` / `loopEnd`(秒)に `duration`(デコード後の長さ・秒)を加える。`duration` がない JSON も読める |
| JSON の書き出し | File System Access API で、保存先を選ぶ書き出しと、読み込んだ(ボタンでもドロップでも)または保存したファイルへの上書き保存ができる。外から変更されていたら確認を出す。クリップボードへのコピーもでき、コピーしても書き出し済みとはしない。保存はファイル全体の置き換えで、保存先の既存の内容には重ねない。読み込んだ JSON の知らないフィールドは残す |
| 複数の音源 | まとめて読み込み、セレクトで切り替える。1 つの JSON に全音源分を書き出す |
| モード | ループとクロップの 2 つ。波形の上のタブで切り替え、動かせる線を分ける。最初はループ。タブの横に今のモードの長さを出し、クロップでは形式の選択と「切り出して保存」も並べる |
| クロップの書き出し | kiln だけで行い、再エンコードはしない。mp3 は mp3(無劣化の切り出し)か WAV(kiln でデコード。kiln で読めない MPEG-2 などは WAV だけ)、FLAC は FLAC(無劣化の切り出し。初期値)か WAV(kiln でデコード。kiln で読めないものは WAV だけ)、Ogg の Opus は Opus(パケットをコピーし、pre-skip と末尾のグラニュール位置で前後を捨てさせる。初期値。拡張子は元の .opus か .ogg)か WAV(ブラウザでデコード)、Ogg の Vorbis は Ogg(パケットをコピーし、末尾はグラニュール位置で捨てさせる。先頭は、Chromium が先頭の切り詰めを守らないので、前端より前のパケットの区切りに寄せ、その位置を知らせる。初期値。拡張子は .ogg だけ)か WAV(ブラウザでデコード)で、Ogg はどちらも、壊れたページがあるもの(Vorbis は先頭の切り詰めのあるものも。kiln の `ogg.probe` の `trimmable` で判定する)や、ブラウザと長さが合わないものは WAV だけ、WAV は元の形式のまま切り出し、m4a の AAC は m4a(フレームをコピーし、編集リストと iTunSMPB の両方で前後を捨てさせる。タイムスケールは元のままで、HE-AAC は 2 サンプル単位。初期値)か WAV(ブラウザでデコード)で、HE-AAC v2 や、ブラウザと長さが合わないものなど、kiln の `m4a.probe` の `trimmable` が false のものは WAV だけ(ALAC はブラウザで開けない)、ほかの形式はブラウザでデコードして WAV にする。WAV にするときは 16-bit で、元のサンプルレートを保つ(分からない形式は `AudioContext` のレート)。ただし、FLAC を kiln でデコードして WAV にするときは、元のビット深度も保つ。壊れたフレームを無音にして書き出したときは、その数を知らせる。FLAC で、ブラウザがデコードした長さと kiln の長さが違うとき(壊れたフレームをブラウザが飛ばし、波形と書き出しの位置がずれる)は、警告して書き出しを止める。ファイル名は `<元の名前>-cropped.<拡張子>` で、保存先の拡張子が書ける形式ならその形式で書く。クロップモードに切り替えたときに kiln で音源を調べ、バイト列を読んでおく。保存先を選んだ時点で Chromium がファイルを空にするので、書き出しではそのバイト列を使い、元の音源への上書き(その場で切り詰める)も許す。PR #8(`wasm-media-encoders` で mp3 と Ogg に再エンコード)は閉じ、この方針で作り直した |
| 元の形式のままの切り出しの進め方 | Opus → Vorbis → m4a の順に、形式ごとに 1 つの PR(kiln の切り出しと画面への組み込みをまとめる)で足す(#16)。各 PR で、作る前に Chromium が前後の余分を捨てる指定を守るかを確かめる。書き出したファイルは Chromium と ffmpeg で確かめ、ゲームエンジン(Unity、Unreal)ではユーザーが手で確かめる |
| クロップ後の動作 | 書き出した音源を開いてループモードに戻る。ループを決めていた音源なら、実際に切り始めた位置を引いた秒数で項目を作り、元の音源と項目は残す。JSON の保存は別の操作。ループを決めた音源で、範囲がループ区間にかかる間は警告して書き出しを止める。長さの情報のない mp3 を無劣化で切るときは、実際の切り始め(先頭の 529 サンプルより後ろ)で判定する。再生は前端から後端まで 1 回 |
| kiln | 音源の解析と書き出しを受け持つ Zig 製のライブラリ(MIT)。このリポジトリの `kiln/` で開発する(#16)。もとは soundkitchen/kiln で開発していて、`1eebfb7` までの履歴を `git subtree` で取り込んだ。soundkitchen/kiln はそのまま残す。ブラウザでできることはブラウザで行い、できない部分を kiln で行う。`kiln/docs/` は kiln の仕様として扱う。画面からは JS 側の包みの `kiln/wasm/kiln.ts`(型つき)を直接 import し、wasm は `npm run kiln:build`(`dev` と `build` の前にも動く)で `kiln/zig-out/kiln.wasm` にビルドする。ビルドした wasm はコミットしない。`npm run build` の最後(`postbuild`)に、`dist/` に `.wasm` が出ていないことを確かめる(別のファイルとして出ると CSP で読めない)。開発サーバーは `.zig/` と `kiln/.zig-cache/` を見張らない(`vite.config.ts`)。wasm はクロップモードに切り替えたときに読むチャンクに埋め込み、バイト列で渡す。CSP は `connect-src 'none'` を保ち、`script-src` に `'wasm-unsafe-eval'` だけを足す。足りない機能は、別のライブラリを足さずに kiln に足す。テストは `npm run kiln:test` |
| 配色 | システム、ライト、ダークから選ぶ。ヘッダーのアイコン 3 つで切り替え、選択は `localStorage` に保存する。初回はシステムに合わせる |
| リポジトリの公開範囲 | public、MIT ライセンス |

## 作業計画

1. リポジトリの整理(完了)
2. ブラウザ内で完結させる(完了): ファイル選択とドラッグ&ドロップ、JSON の読み込みと書き出し、`duration` の記録と不一致の警告、API の削除
3. プロトタイプ固有の記述の整理とドキュメント更新(完了): タイトル、文言、コメント、パッケージ名、ポート番号、favicon、README
4. Cloudflare へのデプロイ(完了): `wrangler.jsonc`、`npm run deploy`

## 手元だけにあるファイル

- `docs/README.md`: 移植元のドキュメント。機能と既知の課題の説明として参照できるが、公開しない(`.git/info/exclude` で除外)
- `sounds/`: 動作確認用の音源。公開しない(`.gitignore` で除外)
- `.zig/`: PATH に Zig がないときに `scripts/kiln.mjs` が取ってきた Zig(`.gitignore` で除外)
