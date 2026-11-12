# K!LN の決定事項

K!LN(識別子は `kiln`)の目的と、これまでに決めたことの記録。設計と検証の詳細は、形式ごとの文書([`architecture.md`](architecture.md) など)にある。

## 1. 目的

Loop Points の音源の解析(音源を開くときの、元のサンプルレートの読み取り)とクロップの書き出しを受け持つ、Zig 製のライブラリ。wasm にして、ブラウザの中で動かす。音声を読み込み、切り出し、形式を選んで書き出す。ブラウザでできること(デコードなど)はブラウザで行い、できない部分(元の形式のままの切り出し、元のサンプルレートの読み取り、ブラウザにないエンコーダなど)を kiln で行う。

きっかけは、Google Gemini Lyria が書き出す MP3 を、再エンコードせずに切り出したいことだった(調査と方式は [`lyria-mp3.md`](lyria-mp3.md))。

## 2. 決めたこと

### 2.1 2026-11-09 に決めたこと

- **目的の整理**: 主機能は「任意の音声を読み込み、クロップして、任意の形式で書き出す」こと(デコード → PCM → クロップ → エンコード)。最初の具体的な対象は Lyria の MP3。
- **最初の到達点**: MP3 → MP3 の無劣化・サンプル精度トリム。方式と検証結果は [`lyria-mp3.md`](lyria-mp3.md)。汎用パイプラインに付け足す「同一形式なら再エンコードしない」最適化と位置づける。
- **構成**: コアは I/O を持たず、wasm はその薄いラッパーにする(当初は CLI も作ったが、2026-11-11 に外した。§2.9)。
- **C2PA マニフェスト**: トリムすると検証に失敗するため、常に削除する(ID3v2 タグ自体は `iTunSMPB` のために付ける)。
- **Zig のバージョン**: 0.17.1。手元は Loop Points のリポジトリ直下の `.envrc`(direnv)で `~/Zig/0.17` を PATH に通す。
- **テスト用の音声**: Lyria の実ファイルは git に入れない。テストには lame で作った、Lyria と同じ構成(CBR 192kbps、Xing なし)の短い MP3 を使い、リポジトリに入れる。
- **MP3 トリムで付ける LAME タグのエンコーダ名**: `LAMEK!LN `(末尾の空白を含めて 9 バイト。LAME タグのこのフィールドは 9 バイト固定)。`LAME` で始めるのは ffmpeg / Chrome に delay / padding を読ませるため。
- **Safari 対応**: トリム結果に ID3v2 の `iTunSMPB` を付ける(値は LAME タグの delay / padding と同じ。詳細は [`lyria-mp3.md`](lyria-mp3.md) §4)。当初は priming に 529 を足し、末尾に 1 フレーム余分に含めていたが、同じ日の再確認で直した(§2.3)。
- **コア API**: [`architecture.md`](architecture.md) の方針で進める。

### 2.2 2026-11-09 に決めたこと(MP3 トリマーの実装)

- **範囲外の指定**: 丸めて続行する(タグなしの入力では先頭を 529 サンプルに切り上げ、末尾はファイルの終わりに切り詰める)。実際に切り出した区間を結果で返し、丸めたことを利用者に伝えるのは呼び出し側。丸めた結果が空ならエラー
- **入力の範囲**: MPEG-1 Layer III なら、Xing / LAME タグ付き(他のエンコーダの出力)も受け付ける。位置は ffmpeg がデコードしたときの先頭を 0 とする(LAME タグの delay を除いた位置)。MPEG-2 / 2.5 は扱わない
- **API**: `kiln.mp3.probe` / `trim`(`*std.Io.Writer` に書く)/ `trimAlloc`。範囲外の丸めはコアが行い、実際に切り出した区間を返す。JS は `mp3.probe` / `mp3.trim`(秒またはサンプル数)。詳細は [`architecture.md`](architecture.md) §2.1、§2.3
- **低ビットレートの入力**: 開始位置の手前に必要なフレームが LAME タグの delay(12bit)に収まらないときだけ、ビットリザーバの中身を詰めた無音フレーム(carrier)を使う。Lyria のような入力では従来どおり元のフレームだけを連結する(詳細は [`lyria-mp3.md`](lyria-mp3.md) §5.2)

### 2.3 2026-11-09 に決めたこと(MP3 トリムの再生確認)

- **`iTunSMPB` の値**: priming / padding を LAME タグの delay / padding と同じ値にする(以前は `delay + 529` / `padding - 529`)。CoreAudio(Safari)はデコーダ遅延の 529 を除いた出力に `iTunSMPB` を当てるため、529 を足すと 529 サンプル余分に落としていた。これで Safari でも ffmpeg / Chrome / Firefox と同じ位置・長さになる
- **末尾のフレーム**: 最後のサンプルを含むフレームまでにする(以前は Safari 向けに 1 フレーム余分に含めていた。余分に落としていた 529 サンプルを補うためのもので、不要になった)。padding が 0 にならないので、Safari の `<audio>` も `iTunSMPB` を使う
- **既知の差として残すもの**: Safari などデコーダ遅延を隠すデコーダは、タグのない元ファイル(Lyria の出力を含む)を ffmpeg より 529 サンプル前にずらして再生する。位置の基準は ffmpeg のまま変えない(詳細は [`lyria-mp3.md`](lyria-mp3.md) §6)
- **Firefox と `<audio>` 要素**: Chrome / Firefox / Safari で確認した(結果は [`lyria-mp3.md`](lyria-mp3.md) §5.4)

### 2.4 2026-11-09 に決めたこと(WAV と MP3 デコーダ)

- **範囲**: WAV の読み込み・サンプル精度の切り出し・書き出しと、MP3 デコーダ(MPEG-1 Layer III)を作る
- **PCM の表し方**: 読み込んだ元の形式(8bit 符号なし、16 / 24 / 32bit 整数、32 / 64bit 浮動小数点)のまま持ち、必要なときだけ変換する。WAV → WAV はビット一致にする
- **ディザ**: 浮動小数点から整数にするときは、既定で TPDF ディザをかける(乱数の種は固定)。オプションで切れる。WAV → WAV のように形式を変えないときは関係しない
- **MP3 → WAV の既定の形式**: 16bit 整数(オプションで変えられる)
- **ライセンスの方針**: できるだけ MIT に近づける。MP3 デコーダの規格の数表(ハフマン符号表、合成窓)は、CC0 の minimp3 から取る(LGPL の ffmpeg からは取らない。[`mp3-decoder.md`](mp3-decoder.md) §1)

### 2.5 2026-11-09 に決めたこと(ライセンス)

- **ライセンス**: MIT。著作権者は Takanobu Izukawa。全文は `kiln/LICENSE`
- **ソースの表示**: すべてのソース(`src/`、`wasm/`、`build.zig`、`testdata/` のスクリプト)の先頭に `SPDX-License-Identifier: MIT` を書く
- **取り込んでよいもの**: 外部のコードや数表は、次のライセンスのものに限る。どれも義務は元の著作権表示を残すこと(CC0 / Unlicense / パブリックドメインは義務もない)だけで、MIT と両立する
  - MIT、BSD-2-Clause、BSD-3-Clause、ISC、Zlib、CC0-1.0、Unlicense、パブリックドメイン
  - Apache-2.0(全文と NOTICE の内容を残す義務、特許条項がある)、宣伝条項付きの BSD-4-Clause、GPL / LGPL などのコピーレフトは取り込まない
- **取り込んだときの記録**: 出所・ライセンス・元の著作権表示を `kiln/THIRD_PARTY_NOTICES.md` に書く。取り込んだファイルの先頭にも、出所と元のライセンスの SPDX 識別子を書く(例: `// SPDX-License-Identifier: MIT AND CC0-1.0`)

### 2.6 2026-11-10 に決めたこと(FLAC)

- **範囲**: デコーダとエンコーダの両方を作る(FLAC → WAV、FLAC → FLAC の切り出し、WAV / MP3 / AudioBuffer → FLAC)
- **FLAC → FLAC の切り出し**: 区間の先頭と末尾にかかるフレームだけ作り直し、ほかのフレームはそのままコピーする(元の圧縮率を保つ)。どちらにしても復号した PCM は元と同じ
- **エンコーダの圧縮**: 線形予測(LPC)と Rice 符号のパラメータ探索まで作り、flac の既定(-5)に近い大きさを目標にする。圧縮の段階は flac / sox / Audacity などと同じ 0〜8(既定 5)から選べ、中身も flac の -0〜-8 に合わせる(ffmpeg は 0〜12)。JS は `compression`
- **書き出すビット深度**: 整数の WAV は元のビット深度、浮動小数点の入力(MP3 のデコード結果、AudioBuffer、浮動小数点の WAV)は既定で 16bit(TPDF ディザ)。JS は `bitsPerSample`(4〜32)
- **JS の API**: 入力ごとに分ける(`flac.encode(AudioBuffer か Float32Array[])`、`wav.toFlac`、`mp3.toFlac`、`flac.trim`)
- **MD5**: 書き出す FLAC の STREAMINFO に PCM の MD5 を入れる(FLAC → FLAC の切り出しでも、区間をすべて復号して計算する)
- **メタデータ**: FLAC → FLAC では Vorbis コメント・画像・APPLICATION を残し、STREAMINFO(長さと MD5)は作り直す。シークテーブルと CUE シートは位置がずれるので捨てる
- **切り出しの細部**(設計は [`flac.md`](flac.md) §7): 最後を除くフレームがそろえば固定ブロック長、そうでなければ可変ブロック長で、最後を除くフレームを 192 サンプル以上にする(Safari が読めるように。§7.2)。作り直すフレームは段階 8 で符号化する。壊れたフレームは無音として作り直す。PADDING と壊れたメタデータブロックは書かない
- **検証**: 参照実装の `flac` / `metaflac`(Homebrew)と ffmpeg、FLAC の公式テストファイル(CC0、リポジトリには入れない)と突き合わせる。テスト用の FLAC は `flac` で作ってリポジトリに入れる
- **デコーダの細部**(設計は [`flac.md`](flac.md)): 仕様は RFC 9639 から自分で書く。Ogg FLAC は扱わない。FLAC → WAV の既定の形式はビット深度を保つもの(可逆)。CRC が合わないなど壊れたフレームは、libFLAC と同じく無音にして数を返す

### 2.7 2026-11-10 に決めたこと(wasm の読み込み)

- **`load` の既定の読み込み先**: 持たない。kiln.js に既定の URL(`import.meta.url` を基準にしたもの)を書くと、バイト列で読み込む場合にもバンドラが使わない kiln.wasm を出力するため(soundkitchen/kiln#11、Loop Points から)。2026-11-11 からは、URL も受け取らず、バイト列だけを受け取る(§2.9)

### 2.8 2026-11-10 に決めたこと(Ogg / m4a / aac)

- **進め方**: Ogg(Vorbis / Opus)・m4a・aac(ADTS)は、①解析(probe)→ ②無劣化の切り出し(同じ形式で書き出す)の順に進める。デコーダとエンコーダを作るかどうかは、Loop Points の #16(書き出す形式の方針)で決める
- **PR の分け方**: ①は 3 形式をまとめて 1 つの PR(Loop Points の #14 が元のサンプルレートを必要としているため)。②は形式ごとに 1 つずつ
- **名前**: JS / コアとも `ogg`(Vorbis と Opus。`.opus` もここ)・`m4a`(MP4 コンテナ)・`aac`(ADTS)。拡張子と同じ名前にする
- **ADTS の HE-AAC**: ヘッダでは見分けられない(レートが半分、v2 はチャンネル数も 1 に見える)。kiln は AAC の音声データを読まず、「分からない」(JS の `sbr: null`)を返す。ブラウザでは WebCodecs の `AudioDecoder` に最初のフレームを渡せば実際のレートとチャンネル数が分かる(Chrome で確認。[`aac.md`](aac.md) §3)ので、使う側で補う。AAC の音声データを読む処理(デコーダの前半)を入れて判定する案もあったが、AAC の特許の扱い(§5)を前倒しで決めることになるため、先送りした
- **aac の切り出しの精度**: ADTS には遅延や詰め物を書く場所がないので、そのままではフレーム(1024 サンプル)単位でしか切れない。m4a に入れ替えてサンプル精度で切る案と、使い勝手を比べて aac の切り出しの PR で決める
- **テスト用のファイル**: opusenc / oggenc(Homebrew の opus-tools と vorbis-tools)、ffmpeg、afconvert(macOS)で作る

### 2.9 2026-11-11 に決めたこと(Loop Points への取り込みと整理)

- **開発の場所**: kiln を使うのは Loop Points だけなので、Loop Points のリポジトリの `kiln/` で開発する(Loop Points の #16、#17)。soundkitchen/kiln の `1eebfb7` までを、`git subtree` で履歴ごと取り込んだ。soundkitchen/kiln はそのまま残す
- **ビルド**: ビルドした wasm はコミットしない。Loop Points の `npm run dev` / `npm run build` の前に、`scripts/kiln.mjs` が `zig-out/kiln.wasm` をビルドする。Loop Points は `wasm/kiln.ts` をソースから直接 import する
- **外したもの**: 単体のライブラリとして配るための部分を外した
  - CLI(`kiln trim` / `kiln info`)
  - `load` の URL からの読み込み(fetch)。Loop Points は CSP で fetch を止め、wasm をバイト列で渡すため
  - `zig-out/wasm/` への kiln.js・kiln.d.ts・LICENSE のコピー
  - kiln.d.ts の WebWorker 用と ES だけの環境用の型検査
  - `build.zig.zon` の配布用のファイル一覧(Zig が必須とするので、ディレクトリ全体を指す形にした)
- **残したもの**: 音を扱う API はすべて残す。FLAC への変換やデコードは、Loop Points の #16 の書き出しの方針で使う
- **JS 側の包み**: 使うのが Loop Points(TypeScript)だけなので、`kiln.js` と型定義の `kiln.d.ts` を 1 つの `kiln.ts` にまとめた。型は Loop Points と同じ tsc で確かめ、手作業で合わせていた型定義と、その型検査(`wasm/types/`)をなくした。誤った使い方が型エラーになることの検査だけは、型をうっかり緩めないよう `wasm/test/types.ts` に残した。Node のテストが kiln.ts を型を消して読むので、`kiln/wasm/tsconfig.json` で型を消すだけで動く書き方(`erasableSyntaxOnly`)を確かめる。mp3 / wav / flac の各経路の実行時のテスト(`wasm/test/convert.test.mjs`)を足した

### 2.10 2026-11-11 に決めたこと(Opus の切り出し)

- **進め方**: 元の形式のままの切り出しを、Opus → Vorbis → m4a の順に、形式ごとに 1 つの PR(kiln の切り出しと Loop Points への組み込みをまとめる)で足す(Loop Points の #16)。各 PR で、作る前に Chromium が前後の余分を捨てる指定を守るかを確かめる。書き出したファイルは Chromium と ffmpeg で確かめ、ゲームエンジンでは手で確かめる
- **Opus の方式**: パケットをコピーし、区間の前に 80ms 残す。前後の余分は pre-skip と最後のページのグラニュール位置で捨てさせる。Chromium(`decodeAudioData`)と ffmpeg で、長さと位置が区間どおりになることを確かめた([`ogg.md`](ogg.md) §6)
- **扱わない入力**: 読めないページや欠けたページがあるものは切り出さない(`InvalidOgg`)

### 2.11 2026-11-11 に決めたこと(Vorbis の切り出し)

- **確かめた事実**: Chromium(`decodeAudioData`)と ffmpeg は、最後のページのグラニュール位置による末尾の切り詰めは守るが、最初のページのグラニュール位置による先頭の切り詰め(Vorbis I §A.2)は守らない(切り詰めずにデコードする)。また、音声が 1 ページだけで末尾を切り詰めたファイルは、Chromium がデコードに失敗し、ffmpeg は切り詰めない
- **Vorbis の方式**: 先頭は、区間の先頭を含むパケットの区切りに寄せる(手前に寄せる。Loop Points のユーザーが選んだ)。そのパケットの前のパケット(重ね合わせの相手)からコピーし、それだけを最初の音声ページ(グラニュール位置 0)に置く。末尾は最後のページのグラニュール位置で捨てさせる。Chromium と ffmpeg で、長さと位置が区間どおりになることを確かめた([`ogg.md`](ogg.md) §7)
- **扱わない入力**: 先頭の切り詰めのある Vorbis(`UnsupportedFormat`。ブラウザが切り詰めを守らず、解析の位置とデコード結果の位置が合わないため)。読めないページや欠けたページがあるもの(`InvalidOgg`)。どちらも `ogg.probe` の `trimmable` を false にし、使う側が書き出す前に判定できるようにする(Loop Points の PR #22 のレビューで、ブラウザとの長さの比較では 1〜2 サンプルの切り詰めを見分けられないと分かったため。ユーザーの判断)

### 2.12 2026-11-11 に決めたこと(m4a の切り出し)

- **確かめた事実**: Chromium(`decodeAudioData`)と ffmpeg は、m4a の編集リスト(elst)による前後の切り詰めをどちらも守る。編集リストがなく iTunSMPB だけのものも守る。Apple のデコーダは編集リストを読まず iTunSMPB だけを読む。Chromium は ALAC をデコードできない(元のファイルも)
- **AAC の方式**: 区間を含むフレームを、前の 2 フレームと後ろの 1 フレームと一緒にコピーし、前後の余分を編集リストと iTunSMPB の両方で捨てさせる(どちらか一方しか読まないプレイヤーのため。Loop Points のユーザーが選んだ。macOS の Apple のデコーダは iTunSMPB だけを読む)。タイムスケールは元のままにする。Apple は HE-AAC の iTunSMPB を中心のレートの単位で、ffmpeg はタイムスケールの単位で読むので、両方で合うのは中心のレートのタイムスケールのときだけ。そのため HE-AAC は 2 サンプル単位で切る(先頭は切り捨て、終わりは切り上げ。Loop Points の PR #23 のレビューで分かり、ユーザーが選んだ)。後ろのフレームがないと、短い区間で Chromium がデコードに失敗し ffmpeg は何も出さないので、入力の末尾では最後のフレームを繰り返す。Chromium と ffmpeg で、長さと位置が区間どおりになることを確かめた([`m4a.md`](m4a.md) §5)
- **扱わない入力**: ALAC(Chromium で開けず使い道がないので、AAC だけにする。Loop Points のユーザーが選んだ)。HE-AAC v2(PS のステレオの情報がときどきしか送られず、途中から復号すると左右が元と違う)。ほかに、SBR / PS の有無が分からないもの、タイムスケールがデコード結果のレートの整数分の 1 でないもの、空の編集や複数の編集のある編集リスト、遅延と長さがメディアに収まらない編集リスト、サンプルの説明が複数あるもの、stz2、データが入力の外を指すもの。どれも `m4a.probe` の `trimmable` を false にし、`m4a.trim` は `UnsupportedFormat` を返す

### 2.13 2026-11-12 に決めたこと(音源を開くときの解析)

- **使う場面**: Loop Points は、クロップの書き出しだけでなく、音源を開くたびに kiln の解析(`wav.probe` / `mp3.probe` / `flac.probe` / `ogg.probe` / `m4a.probe`)で元のサンプルレートを調べ、そのレートのままデコードする(Loop Points の #14)。wasm は、最初の音源を開くときに読み込む(Loop Points のユーザーが選んだ。それまではクロップモードに切り替えたとき)
- **レートが分からないもの**: 解析で読めないもの(MPEG-2 の mp3 など)と、SBR の有無が分からない m4a(`sbr` が null)は、Loop Points が出力の機器のレートで扱う。aac(ADTS)は、ヘッダから HE-AAC かどうかが分からない(§2.8)ので、`aac.probe` は使わず、同じく出力の機器のレートで扱う(Loop Points のユーザーが選んだ)
- **確かめた事実**: Chromium で元のレートの `OfflineAudioContext` でデコードした長さは、解析の `samples` とサンプル単位で一致する(testdata の mp3、WAV、FLAC、Vorbis、Opus、m4a。`vorbis-mono22k.ogg` だけ Chromium が 17 サンプル短い)。kiln に変更はない

### 2.14 2026-11-12 に決めたこと(形式とサンプルレートの判定)

- **きっかけ**: Loop Points が音源を開くたびに解析(`probe`)をまるごと呼び、レートしか使っていなかった(§2.13)。入力全体を wasm のメモリに写すので、大きな WAV でメモリが増えたまま残る(Loop Points の #26)
- **関数の形**: `kiln.detect(input)` が形式とサンプルレート(`{ format, sampleRate }`)を返す(Loop Points のユーザーが選んだ。レートだけ、チャンネル数も、の案もあった)。コアにあった形式の判定(`detect`)にレートを足し、wasm と kiln.ts に出す。設計は [`architecture.md`](architecture.md) §2.2.1
- **渡す範囲**: Loop Points は先頭の 64KB を渡し、ヘッダーが入っていなければ全体を渡し直す(Loop Points のユーザーが選んだ)。そのため `detect` はヘッダーだけを読み、入力が途中で切れていても読めるようにする。足りないことを知らせるエラーは作らず、渡し直すかどうかは呼ぶ側で決める。Loop Points は、先頭に ID3v2 タグがあればその長さの分も足して渡し、渡し直すのは、形式が WAV(`fmt ` が後ろ)か m4a(moov が後ろ)でレートが null のときだけにする(PR のレビューで決めた。SBR があるか分からない m4a は、moov が後ろの m4a と見分けられないので、全体をもう 1 回読む)
- **MP3 の判定**: `detect` は、最初のフレームを先頭(ID3v2 タグの後ろ)の 64KiB の中でだけ探す。MP3 には印がなく、入力の奥まで探すと、MP3 でない入力で偶然フレームに見える並びを拾うため(PR のレビューで決めた)。Loop Points は、それまでと同じく、拡張子が .mp3 のときだけ MP3 の判定を使う
- **kiln が扱えない種類**: ヘッダーに書かれたレートを返す(Loop Points のユーザーが選んだ)。MPEG-2 / 2.5 の MP3、kiln が読めない符号化の WAV(μ-law など)、RF64、RIFX、連結した Ogg、壊れた FLAC が、元のレートで開けるようになる。それまで Loop Points 側にあった Ogg と FLAC のヘッダー読みは、kiln に移った
- **確かめた事実**: Chromium は、MPEG-2(16 / 22.05 / 24kHz)と MPEG-2.5(8 / 11.025 / 12kHz)の Layer III、μ-law と A-law の WAV を、ヘッダーのレートの `OfflineAudioContext` でそのままデコードできる(長さは、レートを掛けた値と一致)。Layer II、ADPCM、64bit 浮動小数点の WAV は、レートによらずデコードできない
- **レートを読まないもの**: aac(ADTS)と、SBR があるか分からない m4a は、これまでどおり null(§2.8、§2.13)

### 2.15 2026-11-12 に決めたこと(クロップの準備での形式の判定)

- **きっかけ**: Loop Points のクロップの準備は、WAV → MP3 → FLAC → Ogg → m4a の順に、合う形式が見つかるまで解析(`probe`)を試していた。m4a なら 3 回呼び、そのたびに入力をまるごと wasm のメモリに写していた。形式の判定も、音源を開くとき(`detect`)と 2 か所にあった(Loop Points の #28)
- **方式**: クロップの準備でも `detect`(先頭だけを渡す)で形式を判定し、その形式の解析だけを呼ぶ。開くときの結果は持ち回らず、もう一度 `detect` を呼ぶ(Loop Points のユーザーが選んだ。先頭だけなので軽い)
- **判定できなかったとき**: 拡張子が .mp3 なら `mp3.probe` を試す(Loop Points のユーザーが選んだ)。`detect` は MP3 の最初のフレームを先頭の 64KiB の中でしか探さないが、`mp3.probe` は入力の終わりまで探すので、先頭に大きなゴミがある MP3 も、それまでどおり MP3 のまま切り出せる。ほかの拡張子は解析を呼ばない
- **確かめた事実**: 79 通りの入力(testdata と手元の音源。名前と中身が違うもの、先頭にゴミや大きな ID3v2 タグがあるものを含む)で、選べる形式と解析の結果は変わらず、解析を呼ぶ回数は 151 回から 66 回(1 つの入力につき 1 回以下)になった。kiln に変更はない

## 3. まだ決めていないこと

書き出せる形式とその順番、エンコーダを kiln に持たせるか(Ogg Vorbis、mp3)、wasm を形式ごとに分けるかなどは、Loop Points の #16 で扱う。

## 4. 調べて分かった事実(判断材料)

- **Zig の最新安定版は 0.17.1**(2026-11-02、公式ダウンロードページで確認)。Zig は 1.0 前で破壊的変更が入りやすい。0.16 以前の記事やライブラリのコードは API が違う可能性があるので、写す前に 0.17 のリリースノートと標準ライブラリのドキュメントで確認すること。
- 参考になりそうな既存物:
  - Zig 製の FLAC デコーダ(pure Zig、FLAC 公式テストスイートで検証済み): `zff.dev/audiophile/flac`
  - Zig 製の音声ライブラリ `braheezy/zigaudio`(wav / flac / mp3 / ogg / aac などの読み書きを目指している)
  - Rust の Symphonia(デコード専用、pure Rust): デコード結果の比較対象に使える
- ブラウザ側の制約:
  - `decodeAudioData` の出力は AudioContext のサンプルレートにリサンプルされる。
  - 長尺音声はメモリが大きい(float32 ステレオ 44.1kHz の 10 分で約 210MB)。
  - Safari の Ogg 対応は 18.4 以降で改善したとされるが、Ogg Opus は不完全という報告もある。

## 5. 注意事項

- **AAC のライセンス**: Via LA の特許プールが、AAC のエンコーダ・デコーダを含む最終製品のメーカー/開発者にライセンスを求めている。AAC-LC の特許は失効したという見方が有力(Red Hat が 2017 年に判断)だが、国ごとに満了時期が異なり公的な宣言はない。HE-AAC v2 や xHE-AAC は有効とされる。扱うなら feature flag でデフォルト無効にするのが無難。商用利用や配布を考える段階で専門家に確認すること。今の kiln は AAC のコンテナ(m4a・ADTS)のヘッダと設定を読み、m4a ではさらに AAC のフレームをそのままコピーして切り出す(§2.12)。AAC の音声データを復号することはない(デコーダはない。§2.8)。MP3 の特許は米国・EU で失効済み。
- MP3 は先頭にエンコーダ遅延ぶんの無音が入る形式で、補正情報(LAME タグ)をプレイヤーが読むかは環境しだい。ループや厳密なタイミングが要る用途には WAV か Opus が向く。
