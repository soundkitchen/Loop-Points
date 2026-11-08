# Loop Points

音源のループポイント(ループする区間の開始と終了)を波形を見ながら決め、JSON に書き出す web ツール。音源の前後を切り落として書き出すクロップもできる。ゲーム開発中に作ったプロトタイプを汎用化したもので、機能と使い方は `README.md` にまとめている。

## 決定事項

| 項目 | 内容 |
|---|---|
| 名前 | 画面タイトルは `Loop Points`、GitHub リポジトリは `Loop-Points`、`package.json` の `name` と Cloudflare の Worker 名は `loop-points` |
| 処理の場所 | ブラウザ内で完結させる。音源はアップロードしない |
| デプロイ先 | Cloudflare(Workers の静的アセット)。アカウントは `Privates` で、`wrangler.jsonc` の `account_id` に書く。公開 URL は https://loop-points.soundkitchen.workers.dev/ で、誰でも開ける。`public/_headers` で CSP を付ける |
| デプロイの方法 | `main` への push のたびに Workers Builds が自動でデプロイするので、マージがデプロイの判断になる。マージ前のビルドの確認はない。失敗しても公開版は前のバージョンのままで、失敗はダッシュボードの Deployments タブのビルド履歴で確認する。手動のデプロイ(`npm run deploy`)はユーザーの指示を受けてから `main` で行う |
| Workers Builds の設定 | ダッシュボードにあり、リポジトリには残らない。ブランチは `main`、ビルドコマンドは `npm run build`(`wrangler.jsonc` には `build` を書かない。書くと `wrangler deploy` がもう一度ビルドする)、デプロイコマンドは `npx wrangler deploy`、パスは `/`、プレビュービルドとビルドキャッシュはオフ、Build watch paths は既定(すべて) |
| Node | `^24.22.1 \|\| >=26.12.1`。それぞれのセキュリティ更新を適用したバージョン以降とし、`package.json` の `engines` に書く。Workers Builds のビルドは `.node-version` で固定し、セキュリティ更新に合わせて上げる |
| 対象ユーザー | 自分やチーム |
| JSON の形式 | ファイル名ごとの `loopStart` / `loopEnd`(秒)に `duration`(デコード後の長さ・秒)を加える。`duration` がない JSON も読める |
| JSON の書き出し | クリップボードへのコピーはどのブラウザでもできる。Chromium 系は File System Access API で、保存先を選ぶ書き出しと、読み込んだ(ボタンでもドロップでも)または保存したファイルへの上書き保存ができる。外から変更されていたら確認を出す。それ以外のブラウザは `loops.json` のダウンロードで、成否は判定できないので押した時点で書き出し済みとする。コピーしても書き出し済みとはしない。保存はファイル全体の置き換えで、保存先の既存の内容には重ねない。読み込んだ JSON の知らないフィールドは残す |
| 複数の音源 | まとめて読み込み、セレクトで切り替える。1 つの JSON に全音源分を書き出す |
| モード | ループとクロップの 2 つ。波形の上のタブで切り替え、動かせる線を分ける。最初はループ |
| クロップの書き出し | WAV、mp3(192kbps)、Ogg Vorbis(品質 6)から選ぶ。初期値は元の形式で、書き出せない形式の音源は WAV。元が WAV ならバイト列を切り出し、それ以外の WAV は 16-bit。ファイル名は `<元の名前>-cropped.<拡張子>` |
| クロップ後の動作 | 書き出した音源を開いてループモードに戻る。ループを決めていた音源なら、前を切った分を引いた秒数で項目を作り、元の音源と項目は残す。JSON の保存は別の操作。ループを決めた音源で、範囲がループ区間にかかる間は警告して書き出しを止める。再生は前端から後端まで 1 回 |
| エンコーダ | `wasm-media-encoders`(LAME と libvorbis)。書き出すときに読み込む。CSP の `connect-src 'none'` を保つため、wasm はチャンクに埋め込み、バイト列で渡す。CSP には `'wasm-unsafe-eval'` を足す |
| mp3 のタグ | ライブラリの出力には長さの情報がないので、`src/mp3Tag.ts` で Info フレームを足す。これで Chrome、Firefox、Safari の位置と長さが揃う。エンコーダ名を LAME にすると Safari が長さを読み違えることがあるので、`Lavc` にする |
| 第三者のライセンス | Loop Points は MIT のまま。LAME(LGPL v2)、libvorbis と libogg(BSD)、`wasm-media-encoders`(MIT)の条文、版、ソースの入手先を `public/THIRD_PARTY_NOTICES.txt` に載せ、画面の「操作」からリンクする。`wasm-media-encoders` を上げるときは、このファイルの版とコミットも直す。LAME は `wasm-media-encoders` が使うフォーク(公式の 3.100 との差は標準エラーへの出力を止める 2 行)のまま使う。公式版にするには `mp3.wasm` を自分でビルドする必要があり、手間に見合わないと判断した |
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
