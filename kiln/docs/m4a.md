# m4a(MP4 コンテナの AAC / ALAC)

m4a の読み込み(`src/m4a.zig`、`src/m4a/` の `box` / `asc`)の設計と検証の記録。今は解析(`kiln.m4a.probe`)だけで、切り出しは後の PR で足す。決定事項は [`draft.md`](draft.md) §2.8。

## 1. 扱う範囲と出所

- コンテナは ISO/IEC 14496-12(ISO Base Media File Format)と 14496-14(MP4)、AAC の設定は 14496-3 §1.6.2.1(AudioSpecificConfig)、記述子は 14496-1(ES_Descriptor など)。Apple の `iTunSMPB` と QuickTime のサンプルエントリの版 1 も読む。外部のコードや表は取り込んでいない
- 先頭が `ftyp` ボックスでなければ `NotM4a`。`moov` がない・ボックスの長さが壊れている・サンプルの表(`stts` と `stsz`)が食い違う・長さの合計(`stts`、編集リスト)が 64 ビットを超える・サンプルレートが 0 などは `InvalidM4a`
- 最初の音声トラック(`hdlr` が `soun`)を見る。`hdlr` を読めないトラック(ボックスの長さが壊れているなど)は飛ばす。中身は AAC(`mp4a` で、記述子のオブジェクトタイプが MPEG-4 Audio か MPEG-2 AAC)と ALAC(`alac`)だけ。MP3 などの別のコーデック、音声トラックがないもの、断片化した MP4(`mvex` や `moof` がある)、QuickTime のサンプルエントリの版 2 は `UnsupportedFormat`
- 音声データ(`mdat`)は読まない。最後のボックス(多くは `mdat`)が途切れていても、`moov` を読めていれば構わない

## 2. サンプルレートとチャンネル数

**AAC**: `esds` の DecoderSpecificInfo(AudioSpecificConfig。QuickTime では `wave` の中にあることもある)を読む。

- オブジェクトタイプ、サンプルレート、channelConfiguration(1〜6、7 → 8、11 → 7、12 / 14 → 8、13 → 24。0 はプログラム設定からチャンネル数を数える)
- SBR / PS の印は 2 通りある。先頭のオブジェクトタイプが 5(SBR)/ 29(PS)で、出力のレートと中心の方式が続くもの(明示的・階層的)と、中心の設定の後ろに同期ワード 0x2B7 と SBR の有無・出力のレート、0x548 と PS の有無が続くもの(後方互換)。ffmpeg は AAC-LC にも「SBR なし」を書き、afconvert は HE-AAC に後方互換の印を書く
- 印がないとき(暗黙の印。SBR は音声データの中にしかない): 中心のレートが 24kHz を超えるなら SBR はない(HE-AAC の中心は 24kHz まで)。メディアのタイムスケールかサンプルエントリのレートが中心の 2 倍なら SBR がある。どちらでもなければ分からない(`sbr` は null)
- PS は SBR の上でモノラルを 2 チャンネルに広げるもの。SBR がないか、中心がモノラルでなければ PS はない。分からなければ `ps` は null
- 結果のサンプルレートとチャンネル数はデコード結果のもの(SBR があれば出力のレート、PS があれば 2 チャンネル)
- AudioSpecificConfig のバイト列もそのまま返す(WebCodecs の `AudioDecoder` の `description` に使える)

**ALAC**: サンプルエントリの中の `alac` ボックス(ALACSpecificConfig)のビット深度・チャンネル数・サンプルレート。

## 3. 長さ

メディアの長さ(タイムスケールの単位)は `stts` の合計。そこから先頭の遅延と末尾の詰め物を除いた長さを、次の順で求める。

1. **編集リスト(`edts` / `elst`)**: 各編集の長さ(ムービーのタイムスケールの単位)をメディアのタイムスケールに直して足す。空の編集(media_time が -1。無音を挟む)も長さに含める。長さ 0 の編集はメディアの最後まで。先頭の遅延は、最初の空でない編集の開始位置(ffmpeg は AAC で 1024)
2. **`iTunSMPB`**(編集リストがないとき。`moov` か `trak` の `udta` / `meta` / `ilst` / `----`): 2 つ目の値が遅延、4 つ目が長さ(16 進)。長さが 0 か、遅延と長さの和がメディアの長さを超えるときは使わない(あふれないように、遅延と「メディアの長さ − 遅延」とで比べる)。afconvert は AAC で遅延 2112 と長さを書く。値はメディアのタイムスケールの単位(afconvert の HE-AAC は中心の 22.05kHz の単位)
3. どちらもなければ、メディアの長さをそのまま使う(遅延は 0)

最後に、タイムスケールの単位からデコード結果のサンプルレートの単位に直す(HE-AAC で、タイムスケールが中心のレートのときは 2 倍になる)。`meta` は ISO ではフルボックス、QuickTime ではただのボックスなので、中身が `hdlr` で始まるかで見分ける。

## 4. 検証

- テスト用のファイル(`testdata/` の ffmpeg の AAC-LC、afconvert の AAC-LC・HE-AAC・HE-AAC v2・ALAC)で、プロファイル・SBR / PS・サンプルレート・チャンネル数・長さ・遅延が ffprobe と元の長さに一致する(HE-AAC の遅延は、iTunSMPB の 2112 を 44.1kHz に直した 4224)
- 61 秒の曲を ffmpeg の AAC、afconvert の AAC-LC・HE-AAC・ALAC に変換したもので、長さが元の WAV と同じ 2,699,136 サンプルになる
- テスト用のファイルを壊したり途中で切ったりした入力で、Debug ビルドが止まらない
