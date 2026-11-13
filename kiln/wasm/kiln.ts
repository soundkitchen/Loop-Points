// SPDX-License-Identifier: MIT
// K!LN の JS ラッパー。kiln.wasm を読み込み、export 関数を JS から使いやすくする。
// 型は Loop Points の tsc(npm run build と、npm run kiln:test の kiln/wasm/tsconfig.json)で確かめる。
// Node のテストはこのファイルを型を消してそのまま読むので、型を消すだけで動く書き方にする
// (enum や namespace、コンストラクタの引数のプロパティは使わない。kiln/wasm/tsconfig.json の erasableSyntaxOnly で確かめる)。

// ---- 型 ----

/**
 * kiln のコアが返すエラーの名前。wasm/main.zig の `KilnError` と同じ一覧にする(足したら両方を直す)。
 * - `NotMp3` / `NotWav` / `NotFlac` / `NotOgg` / `NotM4a` / `NotAac`: その形式のファイルではない
 * - `UnsupportedFormat`: 扱えない種類(MPEG-2 の MP3、RF64 や圧縮形式の WAV、Ogg FLAC、Speex、
 *   連結・多重化した Ogg、AAC / ALAC 以外の MP4、断片化した MP4 など)
 * - `InvalidWav`: WAV が壊れている(`fmt ` / `data` チャンクがない、値が不正)
 * - `InvalidFlac`: FLAC が壊れている(STREAMINFO がない・先頭にない、メタデータブロックの長さが不正など)
 * - `InvalidOgg`: Ogg が壊れている(Vorbis / Opus のヘッダがない・不正など)
 * - `InvalidM4a`: m4a が壊れている(`moov` がない、ボックスの長さやサンプルの表が不正など)
 * - `EmptyRange`: 範囲を丸めた結果、区間が空になった
 * - `TooLarge`: 出力が大きすぎる(WAV は 4GiB まで)
 * - `OutOfMemory`: メモリが足りない
 * - `InvalidOptions`: 書き出しの指定が不正(サンプルレートやチャンネル数など)
 * - `InternalError`: kiln の不具合(起きるはずのない食い違い)
 */
export type KilnErrorCode =
  | 'NotMp3'
  | 'NotWav'
  | 'NotFlac'
  | 'UnsupportedFormat'
  | 'InvalidWav'
  | 'InvalidFlac'
  | 'NotOgg'
  | 'InvalidOgg'
  | 'NotM4a'
  | 'InvalidM4a'
  | 'NotAac'
  | 'EmptyRange'
  | 'TooLarge'
  | 'OutOfMemory'
  | 'InvalidOptions'
  | 'InternalError';

/**
 * 入力のバイト列。ArrayBuffer / SharedArrayBuffer / 任意の TypedArray / DataView を受け取る
 * (TypedArray と DataView は、要素の値ではなく下のバイト列として読む)
 */
export type BytesInput = ArrayBufferLike | ArrayBufferView;

/** WAV のサンプル形式(8bit 符号なし、16 / 24 / 32bit 整数、32 / 64bit 浮動小数点) */
export type SampleFormat = 'u8' | 'i16' | 'i24' | 'i32' | 'f32' | 'f64';

/** 浮動小数点から整数にするときのディザ */
export type Dither = 'tpdf' | 'none';

/** 区間の先頭。秒(`start`)かサンプル数(`startSample`)のどちらか一方。省くと先頭から */
type StartOption =
  | { start?: number; startSample?: undefined }
  | { start?: undefined; startSample?: number | bigint };

/** 区間の終わり(この位置は含まない)。秒(`end`)かサンプル数(`endSample`)のどちらか一方。省くと末尾まで */
type EndOption =
  | { end?: number; endSample?: undefined }
  | { end?: undefined; endSample?: number | bigint };

/** 区間の指定。範囲外は丸める(実際の区間は戻り値の `startSample` / `endSample` で分かる) */
export type RangeOptions = StartOption & EndOption;

/** 実際に処理した区間 */
export interface RangeResult {
  startSample: number;
  endSample: number;
  /** 秒 */
  start: number;
  /** 秒 */
  end: number;
}

/** WAV の書き出しの指定 */
export interface WavFormatOptions {
  /** 既定は `'i16'`(`flac.toWav` はビット深度を保つ形式) */
  format?: SampleFormat;
  /** 既定は `'tpdf'`(浮動小数点から整数にするときと、整数のビット数を減らすときに効く) */
  dither?: Dither;
}

/** FLAC の書き出しの指定 */
export interface FlacFormatOptions {
  /** ビット深度(4〜32)。既定は 16(`wav.toFlac` は、整数の WAV なら元のビット深度) */
  bitsPerSample?: number;
  /** 圧縮の段階(0〜8。flac コマンドの -0〜-8 と同じ)。既定は 5 */
  compression?: number;
  /** 既定は `'tpdf'`(浮動小数点から整数にするときと、整数のビット数を減らすときに効く) */
  dither?: Dither;
}

/** `wav.encode` / `flac.encode` が受け取る PCM。`AudioBuffer` はこの形を満たす */
export interface AudioBufferLike {
  readonly numberOfChannels: number;
  readonly sampleRate: number;
  getChannelData(channel: number): Float32Array;
}

export interface Mp3Info {
  sampleRate: number;
  channels: number;
  /** タイムラインの長さ(サンプル数。ffmpeg でデコードしたときの長さ) */
  samples: number;
  /** 音声フレームの数 */
  frames: number;
  /** 無劣化の切り出し(`trim`)で指定できる先頭の最小値(タグのない MP3 では 529) */
  minStart: number;
  /** 秒 */
  duration: number;
}

export interface WavInfo {
  sampleRate: number;
  channels: number;
  format: SampleFormat;
  samples: number;
  /** 秒 */
  duration: number;
}

export interface FlacInfo {
  sampleRate: number;
  channels: number;
  /** ビット深度(4〜32) */
  bitsPerSample: number;
  /** 長さ(サンプル数。実際のフレームから数えたもの) */
  samples: number;
  frames: number;
  /** 秒 */
  duration: number;
}

export interface Mp3 {
  probe(input: BytesInput): Mp3Info;
  /** 再エンコードせずにサンプル単位で切り出す。結果は MP3 のバイト列 */
  trim(input: BytesInput, options?: RangeOptions): RangeResult & { data: Uint8Array<ArrayBuffer> };
  /** デコードする。`channels` はチャンネルごとの PCM(AudioBuffer の getChannelData と同じ並び)で、元のサンプルレートのまま */
  decode(
    input: BytesInput,
    options?: RangeOptions,
  ): RangeResult & { channels: Float32Array<ArrayBuffer>[]; sampleRate: number; invalidFrames: number };
  /** デコードして WAV にする。`invalidFrames` は復号できなかった(無音にした)フレームの数 */
  toWav(
    input: BytesInput,
    options?: RangeOptions & WavFormatOptions,
  ): RangeResult & { data: Uint8Array<ArrayBuffer>; invalidFrames: number };
  /** デコードして FLAC にする。`invalidFrames` は toWav と同じ */
  toFlac(
    input: BytesInput,
    options?: RangeOptions & FlacFormatOptions,
  ): RangeResult & { data: Uint8Array<ArrayBuffer>; invalidFrames: number };
}

export interface Wav {
  probe(input: BytesInput): WavInfo;
  /** 元の形式のままサンプル単位で切り出す。結果は WAV のバイト列 */
  trim(input: BytesInput, options?: RangeOptions): RangeResult & { data: Uint8Array<ArrayBuffer> };
  /** AudioBuffer(や同じ形のもの)を WAV にする。`sampleRate` を省くと AudioBuffer のもの */
  encode(source: AudioBufferLike, options?: WavFormatOptions & { sampleRate?: number }): Uint8Array<ArrayBuffer>;
  /** チャンネルごとの PCM を WAV にする。どのチャンネルも同じ長さで、`sampleRate` は必須 */
  encode(source: Float32Array[], options: WavFormatOptions & { sampleRate: number }): Uint8Array<ArrayBuffer>;
  /** 区間を FLAC にする。整数の WAV はビット深度を変えなければ可逆 */
  toFlac(input: BytesInput, options?: RangeOptions & FlacFormatOptions): RangeResult & { data: Uint8Array<ArrayBuffer> };
}

export interface Flac {
  probe(input: BytesInput): FlacInfo;
  /**
   * FLAC のまま切り出す(可逆。区間の先頭と末尾にかかるフレームだけを作り直す)。結果は FLAC のバイト列。
   * タグと画像は残し、シークテーブル・CUE シート・PADDING は捨てる。
   * `invalidFrames` は、区間にかかった壊れたフレーム(無音として作り直した)の数
   */
  trim(input: BytesInput, options?: RangeOptions): RangeResult & { data: Uint8Array<ArrayBuffer>; invalidFrames: number };
  /**
   * デコードする。`channels` はチャンネルごとの PCM(整数のサンプルを 2^(bitsPerSample - 1) で割ったもの)。
   * `invalidFrames` は復号できなかった(無音にした)フレームの数
   */
  decode(
    input: BytesInput,
    options?: RangeOptions,
  ): RangeResult & { channels: Float32Array<ArrayBuffer>[]; sampleRate: number; invalidFrames: number };
  /**
   * デコードして WAV にする。`format` を省くとビット深度を保つ形式(8bit 以下は 'u8'、16bit 以下は 'i16'、
   * 24bit 以下は 'i24'、それより多ければ 'i32')で、元の PCM のまま
   */
  toWav(
    input: BytesInput,
    options?: RangeOptions & WavFormatOptions,
  ): RangeResult & { data: Uint8Array<ArrayBuffer>; invalidFrames: number };
  /** AudioBuffer(や同じ形のもの。1〜8 チャンネル)を FLAC にする。`sampleRate` を省くと AudioBuffer のもの */
  encode(source: AudioBufferLike, options?: FlacFormatOptions & { sampleRate?: number }): Uint8Array<ArrayBuffer>;
  /** チャンネルごとの PCM を FLAC にする。どのチャンネルも同じ長さで、`sampleRate` は必須 */
  encode(source: Float32Array[], options: FlacFormatOptions & { sampleRate: number }): Uint8Array<ArrayBuffer>;
}

export interface OggInfo {
  codec: 'vorbis' | 'opus';
  /** デコード結果のサンプルレート(Opus は常に 48000) */
  sampleRate: number;
  /** Opus のエンコード前の音源のサンプルレート。書かれていないとき、Vorbis のときは null */
  inputSampleRate: number | null;
  channels: number;
  /** 再生される長さ(サンプル数)。Opus の pre-skip と、最初と最後のページの切り詰めを除いたもの */
  samples: number;
  /** 秒 */
  duration: number;
  /** Opus の pre-skip(48kHz のサンプル数。Vorbis は 0) */
  preSkip: number;
  /** 読めずに飛ばしたページ(CRC が合わない、途切れた、欠けた)の数 */
  invalidPages: number;
  /**
   * `ogg.trim` で切り出せるか。読めないページや欠けたページがあるものと、先頭の切り詰め(最初のページの
   * グラニュール位置)のある Vorbis は切り出せない
   */
  trimmable: boolean;
}

/** AAC の種類。`he` は HE-AAC(SBR)、`hev2` は HE-AAC v2(SBR と PS)、`other` はそれ以外のオブジェクトタイプ */
export type AacProfile = 'main' | 'lc' | 'ssr' | 'ltp' | 'he' | 'hev2' | 'other';

export interface M4aInfo {
  codec: 'aac' | 'alac';
  /** AAC の種類。SBR / PS が分からないときは中心の方式の名前。ALAC は null */
  profile: AacProfile | null;
  /** AAC の中心の方式のオブジェクトタイプ(2 は LC。SBR / PS の 5 / 29 は含めない)。ALAC は 0 */
  objectType: number;
  /** SBR があるか。ファイルから分からなければ null(そのときは sampleRate が実際の半分のことがある) */
  sbr: boolean | null;
  /** PS があるか。ファイルから分からなければ null(そのときは channels が実際と違うことがある) */
  ps: boolean | null;
  /** デコード結果のサンプルレート(HE-AAC は SBR の後) */
  sampleRate: number;
  /** デコード結果のチャンネル数(HE-AAC v2 は PS の後の 2) */
  channels: number;
  /** ALAC のビット深度。AAC は null */
  bitsPerSample: number | null;
  /** 再生される長さ(サンプル数)。先頭の遅延と末尾の詰め物を除いたもの(編集リストか iTunSMPB から) */
  samples: number;
  /** 秒 */
  duration: number;
  /** 先頭で捨てる遅延(サンプル数) */
  encoderDelay: number;
  /** AAC の AudioSpecificConfig(WebCodecs の AudioDecoder の `description` に使える)。ALAC は空 */
  audioSpecificConfig: Uint8Array<ArrayBuffer>;
  /**
   * `m4a.trim` で切り出せるか。ALAC、HE-AAC v2(PS。途中から復号すると左右が元と違う)、SBR や PS の有無が
   * 分からない AAC、タイムスケールがサンプルレートの整数分の 1 でないもの、遅延と長さがメディアに収まらない編集リスト、
   * 空の編集や複数の編集のある編集リスト、サンプルの説明が複数あるもの、stz2、データが途中で切れているものは切り出せない
   */
  trimmable: boolean;
}

export interface AacInfo {
  /** ADTS のヘッダに書けるのは AAC-LC などの中心の方式だけ */
  profile: 'main' | 'lc' | 'ssr' | 'ltp';
  /** ヘッダの MPEG の版(2 か 4) */
  mpegVersion: number;
  /**
   * 常に null(ADTS のヘッダには SBR / PS を書けない)。HE-AAC なら、デコード結果のレートは sampleRate の 2 倍、
   * v2 なら 2 チャンネルになる。確かめるには WebCodecs の AudioDecoder に最初のフレームを渡す
   */
  sbr: null;
  /** ヘッダのサンプルレート */
  sampleRate: number;
  /** ヘッダのチャンネル数 */
  channels: number;
  frames: number;
  /** 長さ(ヘッダのサンプルレートのサンプル数。フレームあたり 1024)。先頭の遅延も含む */
  samples: number;
  /** 秒 */
  duration: number;
  /** `aac.trim` で切り出せるか。raw_data_block が 2 つ以上のフレーム(m4a の 1 サンプルにできない)があれば false */
  trimmable: boolean;
  /**
   * HE-AAC として(`sbr: true` で)`aac.trim` で切り出せるか。`trimmable` に加えて、出力のレート(ヘッダの 2 倍)を
   * レートの表に書けること(ヘッダのレートが 48kHz 以下で、7350Hz でない)
   */
  sbrTrimmable: boolean;
}

export interface Ogg {
  probe(input: BytesInput): OggInfo;
  /**
   * 再エンコードせずに切り出す。結果は Ogg のバイト列。パケットをそのままコピーし、末尾の余分は最後のページの
   * グラニュール位置で捨てさせる。読めないページや欠けたページがあるものは `InvalidOgg`。
   * - Opus: サンプル単位。区間の前の 80ms と一緒にコピーし、先頭の余分は pre-skip で捨てさせる
   * - Vorbis: 末尾はサンプル単位。先頭は、区間の先頭を含むパケットの区切りに寄せる(`start` は指定以下になる。
   *   44.1kHz の oggenc なら最大 1024 サンプル前)。先頭の切り詰めのあるものは `UnsupportedFormat`
   */
  trim(input: BytesInput, options?: RangeOptions): RangeResult & { data: Uint8Array<ArrayBuffer> };
}

export interface M4a {
  probe(input: BytesInput): M4aInfo;
  /**
   * AAC を再エンコードせずに切り出す。結果は m4a のバイト列。メディアのタイムスケールの単位で区間どおりになる
   * (AAC-LC はサンプル単位。中心のレートのタイムスケールの HE-AAC は 2 サンプル単位で、`start` は指定以下、`end` は
   * 指定以上に寄せる)。区間を含むフレームを前の 2 フレームと
   * 後ろの 1 フレーム(入力の末尾で足りなければ最後のフレームを繰り返す)と一緒にコピーし、前後の余分は
   * 編集リスト(elst)と iTunSMPB の両方で捨てさせる。
   * 切り出せないもの(`trimmable` が false)は `UnsupportedFormat`
   */
  trim(input: BytesInput, options?: RangeOptions): RangeResult & { data: Uint8Array<ArrayBuffer> };
}

export interface Aac {
  probe(input: BytesInput): AacInfo;
  /**
   * 先頭から `limit` 個までのフレームの位置と長さ(ヘッダを含む。`probe` と同じ数え方で、ゴミは読み飛ばす)。
   * WebCodecs の `AudioDecoder` にフレームをそのまま渡して、実際のレートとチャンネル数を調べるのに使う
   */
  frames(input: BytesInput, limit: number): { offset: number; length: number }[];
  /**
   * AAC を再エンコードせずに切り出し、m4a に入れ替えて書く(ADTS には前後の余分を捨てる指定を書く場所がないため)。
   * 結果は m4a のバイト列で、`m4a.trim` と同じく、区間を含むフレームを前の 2 フレームと後ろの 1 フレームと
   * 一緒にコピーし、前後の余分を編集リストと iTunSMPB で捨てさせる。AAC-LC はサンプル単位、HE-AAC は 2 サンプル単位
   * (`start` は指定以下、`end` は指定以上に寄せる)。先頭の遅延はないものとして数える(ブラウザも ffmpeg も ADTS の
   * 先頭を捨てずにデコードする)。
   * `sbr` は HE-AAC か(デコード結果のレートがヘッダの 2 倍か)。ヘッダからは分からないので、WebCodecs の
   * `AudioDecoder` などで確かめて渡す。区間はデコード結果のレートで数える。HE-AAC v2(PS)は渡さないこと
   * (途中から復号すると左右が元と違う)。モノラルの HE-AAC は、PS がないものとして書く。
   * `trimmable`(`sbr` なら `sbrTrimmable`)が false のものは `UnsupportedFormat`
   */
  trim(input: BytesInput, options: RangeOptions & { sbr: boolean }): RangeResult & { data: Uint8Array<ArrayBuffer> };
}

/** 入力の形式(`kiln.detect` の結果) */
export type Format = 'mp3' | 'wav' | 'flac' | 'ogg' | 'm4a' | 'aac';

export interface Detected {
  /** 中身から判定した形式(拡張子は見ない)。kiln が扱えない種類(MPEG-2 の MP3、μ-law の WAV など)もその形式になる */
  format: Format;
  /**
   * デコード結果のサンプルレート(ヘッダーに書かれた値。HE-AAC の m4a は SBR の後、Opus は常に 48000)。
   * 読めなければ null。読めないのは、ヘッダーから決められないもの(aac の ADTS、SBR があるか分からない m4a、
   * Vorbis でも Opus でもない Ogg)と、ヘッダーが入力に入っていないもの(WAV の `fmt `、m4a の moov)
   */
  sampleRate: number | null;
}

export interface Kiln {
  /** ライブラリのバージョン */
  readonly version: string;
  /**
   * 入力のヘッダーから、形式とデコード結果のサンプルレートを読む。音声のデータはたどらないので軽く、
   * 入力はファイルの先頭の一部でもよい。形式が分からなければ null。
   * 先頭の一部を渡して null か `sampleRate` が null になったときは、全体を渡すと読めることがある
   * (大きな ID3v2 タグの後ろの MP3 や FLAC、moov が後ろにある m4a、`fmt ` が後ろにある WAV)
   */
  detect(input: BytesInput): Detected | null;
  /** MP3 の解析、トリム、デコード(PCM、WAV、FLAC) */
  readonly mp3: Mp3;
  /** WAV の解析、切り出し、書き出し(WAV と FLAC) */
  readonly wav: Wav;
  /** FLAC の解析、切り出し、デコード、書き出し */
  readonly flac: Flac;
  /** Ogg(Vorbis / Opus)の解析と切り出し */
  readonly ogg: Ogg;
  /** m4a(AAC / ALAC)の解析と、AAC の切り出し */
  readonly m4a: M4a;
  /** aac(ADTS)の解析 */
  readonly aac: Aac;
  /** 生の export 関数(低レベル API) */
  readonly exports: WebAssembly.Exports;
}

/** wasm のバイト列(WebAssembly.instantiate に渡せるもの) */
export type WasmBytes = ArrayBuffer | ArrayBufferView<ArrayBuffer>;

// ---- wasm の export 関数(wasm/main.zig) ----
// ポインタと長さは wasm の i32(JS では符号付きの number)、u64 は bigint、bool の戻り値は 0 / 1。
// bool の引数には JS の boolean をそのまま渡せる

type Ptr = number;
type ProbeExport = (ptr: Ptr, len: number) => number;
type RangeExport = (ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean) => number;

interface Exports {
  memory: WebAssembly.Memory;
  kiln_alloc(len: number): Ptr;
  kiln_free(ptr: Ptr, len: number): void;
  kiln_alloc_f32(count: number): Ptr;
  kiln_free_f32(ptr: Ptr, count: number): void;
  kiln_version_ptr(): Ptr;
  kiln_version_len(): number;
  kiln_error_ptr(): Ptr;
  kiln_error_len(): number;
  kiln_detect: ProbeExport;
  kiln_value(i: number): bigint;
  kiln_output_ptr(): Ptr;
  kiln_output_len(): number;
  kiln_output_free(): void;
  kiln_mp3_probe: ProbeExport;
  kiln_mp3_trim: RangeExport;
  kiln_mp3_decode: RangeExport;
  kiln_mp3_to_wav(ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean, format: number, dither: number): number;
  kiln_mp3_to_flac(ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean, bits: number, compression: number, dither: number): number;
  kiln_wav_probe: ProbeExport;
  kiln_wav_trim: RangeExport;
  kiln_wav_encode(ptr: Ptr, channels: number, frames: number, sampleRate: number, format: number, dither: number): number;
  kiln_wav_to_flac(
    ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean,
    bits: number, hasBits: boolean, compression: number, dither: number,
  ): number;
  kiln_flac_probe: ProbeExport;
  kiln_flac_format: ProbeExport;
  kiln_flac_decode: RangeExport;
  kiln_flac_to_wav(
    ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean,
    format: number, hasFormat: boolean, dither: number,
  ): number;
  kiln_flac_trim: RangeExport;
  kiln_flac_encode(ptr: Ptr, channels: number, frames: number, sampleRate: number, bits: number, compression: number, dither: number): number;
  kiln_ogg_probe: ProbeExport;
  kiln_ogg_trim: RangeExport;
  kiln_m4a_probe: ProbeExport;
  kiln_m4a_trim: RangeExport;
  kiln_aac_probe: ProbeExport;
  kiln_aac_trim: (ptr: Ptr, len: number, start: bigint, end: bigint, hasEnd: boolean, sbr: boolean) => number;
  kiln_aac_frames: (ptr: Ptr, len: number, limit: number) => number;
}

// ---- 実装 ----

/** WAV のサンプル形式の名前。並びは kiln.pcm.Format と同じ(wasm とは番号でやり取りする) */
const FORMATS: readonly SampleFormat[] = ['u8', 'i16', 'i24', 'i32', 'f32', 'f64'];

/** AAC のオブジェクトタイプ(1〜4)の名前 */
const AAC_PROFILES: Record<number, AacInfo['profile'] | undefined> = { 1: 'main', 2: 'lc', 3: 'ssr', 4: 'ltp' };

/** K!LN のコアが返したエラー。`name` に加えて `code` にコアのエラー名(`NotMp3` など)が入る */
export class KilnError extends Error {
  declare readonly name: 'KilnError';
  readonly code: KilnErrorCode;

  constructor(code: KilnErrorCode) {
    super(`kiln: ${code}`);
    this.name = 'KilnError';
    this.code = code;
  }
}

// load は wasm のバイト列だけを受け取り、URL から fetch しない。Loop Points は CSP の connect-src 'none' で fetch を止め、
// wasm をチャンクに埋め込んでバイト列で渡すため。import.meta.url を基準にした URL をこのファイルに書くと、
// バンドラがそれをアセットの参照とみなし、使わない kiln.wasm をビルド結果に出力する(soundkitchen/kiln#11)。
// コメントや文字列でもその書き方を残さない

/**
 * kiln.wasm を読み込んで初期化する。
 * @param source wasm のバイト列。省けない。バイト列でない値(URL、Response、Blob など)は TypeError で reject する
 */
export async function load(source: WasmBytes): Promise<Kiln> {
  // 別の realm(iframe など)の ArrayBuffer も通すよう、instanceof ではなく型の名前で見る
  const isBytes = ArrayBuffer.isView(source) || Object.prototype.toString.call(source) === '[object ArrayBuffer]';
  if (!isBytes) {
    throw new TypeError('load: pass the bytes of kiln.wasm (an ArrayBuffer or a typed array)');
  }
  const { instance } = await WebAssembly.instantiate(source, {});
  const e = instance.exports as unknown as Exports;
  const decoder = new TextDecoder();
  // export 関数が返すポインタと長さは wasm の i32 で、JS には符号付きで見える
  // (2GiB 以上のアドレスや、長さ 0 の確保が返す 0xFFFFFFFF が負になる)ため、符号なしに直す。
  // memory が伸びると以前のビューは使えなくなるため、読み書きのたびに作り直す
  const bytesAt = (ptr: Ptr, len: number): Uint8Array<ArrayBuffer> => {
    len >>>= 0;
    return len === 0 ? new Uint8Array(0) : new Uint8Array(e.memory.buffer, ptr >>> 0, len);
  };

  /**
   * 入力を linear memory に写して fn(ptr, len) を呼び、終わったら解放する。
   * Uint8Array 以外の TypedArray や DataView は、要素の値ではなくバイト列として扱う
   */
  function withInput<T>(input: BytesInput, fn: (ptr: Ptr, len: number) => T): T {
    const bytes = input instanceof Uint8Array ? input
      : ArrayBuffer.isView(input) ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
        : new Uint8Array(input);
    const ptr = e.kiln_alloc(bytes.length) >>> 0;
    if (ptr === 0) throw new KilnError('OutOfMemory');
    try {
      bytesAt(ptr, bytes.length).set(bytes);
      return fn(ptr, bytes.length);
    } finally {
      e.kiln_free(ptr, bytes.length);
    }
  }

  function check(ok: number): void {
    if (!ok) throw new KilnError(decoder.decode(bytesAt(e.kiln_error_ptr(), e.kiln_error_len())) as KilnErrorCode);
  }

  /** 秒をサンプル位置にする(切り捨て)。浮動小数点の誤差で 1 少なくならないよう、わずかに足す */
  function toSamples(seconds: number, sampleRate: number, label: string): bigint {
    if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) {
      throw new RangeError(`kiln: ${label} must be a non-negative number of seconds`);
    }
    return BigInt(Math.floor(seconds * sampleRate + 1e-6));
  }

  /** サンプル位置を wasm の u64 引数として渡せる BigInt にする(範囲外は RangeError) */
  function toSampleIndex(n: number | bigint, label: string): bigint {
    if (typeof n === 'bigint') {
      if (n < 0n || n > 0xFFFF_FFFF_FFFF_FFFFn) {
        throw new RangeError(`kiln: ${label} must be a non-negative integer below 2^64`);
      }
      return n;
    }
    if (!Number.isSafeInteger(n) || n < 0) {
      throw new RangeError(`kiln: ${label} must be a non-negative integer`);
    }
    return BigInt(n);
  }

  /** 出力のバイト列をコピーして解放する(linear memory の中身は次の呼び出しで変わるため) */
  function takeOutput(): Uint8Array<ArrayBuffer> {
    const data = bytesAt(e.kiln_output_ptr(), e.kiln_output_len()).slice();
    e.kiln_output_free();
    return data;
  }

  /**
   * 区間を指定する処理の共通部分。秒(start / end)かサンプル数(startSample / endSample)を
   * サンプル位置の BigInt にして fn(ptr, len, start, end | null) を呼ぶ。fn は実際の区間を kiln_value(0, 1) に、
   * サンプルレートを kiln_value(2) に置く export を呼び、戻り値に区間を足して返す。
   * probeExport は、秒を位置に直すためのサンプルレートを kiln_value(0) に置く関数(rateScale 倍して使う)
   */
  function rangeWith<T extends object>(
    probeExport: ProbeExport,
    input: BytesInput,
    options: RangeOptions,
    fn: (ptr: Ptr, len: number, start: bigint, end: bigint | null) => T,
    rateScale = 1,
  ): T & RangeResult {
    const { start, end, startSample, endSample } = options;
    if (start !== undefined && startSample !== undefined) {
      throw new TypeError('kiln: specify either start or startSample, not both');
    }
    if (end !== undefined && endSample !== undefined) {
      throw new TypeError('kiln: specify either end or endSample, not both');
    }
    return withInput(input, (ptr, len) => {
      // 秒を位置に直すときだけ、サンプルレートを知るために先に解析する
      let sampleRate = 0;
      if (start !== undefined || end !== undefined) {
        check(probeExport(ptr, len));
        // rateScale: 解析のレートに掛けると、区間を数えるレートになる倍率(HE-AAC の aac は 2)
        sampleRate = Number(e.kiln_value(0)) * rateScale;
      }
      const s = start !== undefined ? toSamples(start, sampleRate, 'start')
        : startSample !== undefined ? toSampleIndex(startSample, 'startSample') : 0n;
      const t = end !== undefined ? toSamples(end, sampleRate, 'end')
        : endSample !== undefined ? toSampleIndex(endSample, 'endSample') : null;
      const result = fn(ptr, len, s, t);
      const r0 = Number(e.kiln_value(0));
      const r1 = Number(e.kiln_value(1));
      sampleRate = Number(e.kiln_value(2));
      return { ...result, startSample: r0, endSample: r1, start: r0 / sampleRate, end: r1 / sampleRate };
    });
  }

  /**
   * トリムの共通処理。trimExport は実際に切り出した区間を kiln_value(0, 1) に、サンプルレートを kiln_value(2) に置く関数
   */
  function trimWith(probeExport: ProbeExport, trimExport: RangeExport, input: BytesInput, options: RangeOptions) {
    return rangeWith(probeExport, input, options, (ptr, len, s, t) => {
      check(trimExport(ptr, len, s, t ?? 0n, t !== null));
      return { data: takeOutput() };
    });
  }

  /**
   * デコードの共通処理。decodeExport はチャンネルごとに並べた f32 を出力に、kiln_value の 0: start、1: end、
   * 2: サンプルレート、3: チャンネル数、4: 復号できなかったフレームの数を置く関数
   */
  function decodeWith(probeExport: ProbeExport, decodeExport: RangeExport, input: BytesInput, options: RangeOptions) {
    return rangeWith(probeExport, input, options, (ptr, len, s, t) => {
      check(decodeExport(ptr, len, s, t ?? 0n, t !== null));
      const nch = Number(e.kiln_value(3));
      const bytes = takeOutput();
      const all = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
      const frames = all.length / nch;
      const channels = Array.from({ length: nch }, (_, i) => all.subarray(i * frames, (i + 1) * frames));
      return { channels, sampleRate: Number(e.kiln_value(2)), invalidFrames: Number(e.kiln_value(4)) };
    });
  }

  /**
   * サンプル形式とディザの名前を wasm に渡す番号にする。fallback は format を省いたときの形式で、
   * null なら format は -1(コアが決める)。型にない名前(JS から渡されたもの)は RangeError
   */
  function formatOptions(options: WavFormatOptions, fallback: SampleFormat | null = 'i16'): { format: number; dither: number } {
    const name = options.format ?? fallback;
    const format = name === null ? -1 : FORMATS.indexOf(name);
    if (name !== null && format < 0) throw new RangeError(`kiln: unknown format '${options.format}'`);
    const dither = ({ tpdf: 1, none: 0 } as Record<string, number | undefined>)[options.dither ?? 'tpdf'];
    if (dither === undefined) throw new RangeError(`kiln: unknown dither '${options.dither}'`);
    return { format, dither };
  }

  /**
   * FLAC の書き出しの指定を wasm に渡す値にする。bits は利用者が渡した bitsPerSample(省いたら undefined。
   * 既定の値は呼ぶ側が決める)。利用者が渡した bitsPerSample は必ず 4〜32 の整数か確かめる
   */
  function flacOptions(options: FlacFormatOptions): { bits: number | undefined; compression: number; dither: number } {
    const bits = options.bitsPerSample;
    if (bits !== undefined && !(Number.isInteger(bits) && bits >= 4 && bits <= 32)) {
      throw new RangeError('kiln: bitsPerSample must be an integer from 4 to 32');
    }
    const compression = options.compression ?? 5;
    if (!(Number.isInteger(compression) && compression >= 0 && compression <= 8)) {
      throw new RangeError('kiln: compression must be an integer from 0 to 8');
    }
    const { dither } = formatOptions({ dither: options.dither });
    return { bits, compression, dither };
  }

  const isAudioBuffer = (source: unknown): source is AudioBufferLike =>
    typeof (source as Partial<AudioBufferLike> | null)?.getChannelData === 'function';

  /**
   * AudioBuffer か Float32Array の配列を、チャンネルごとに続けて linear memory に写して
   * fn(ptr, channels, frames, sampleRate) を呼び、終わったら解放する
   */
  function withPlanar<T>(
    source: AudioBufferLike | Float32Array[],
    options: { sampleRate?: number },
    fn: (ptr: Ptr, channels: number, frames: number, sampleRate: number) => T,
  ): T {
    let channels: unknown = source;
    let sampleRate = options.sampleRate;
    if (isAudioBuffer(source)) {
      channels = Array.from({ length: source.numberOfChannels }, (_, i) => source.getChannelData(i));
      sampleRate ??= source.sampleRate;
    }
    if (!Array.isArray(channels) || channels.length === 0 || !channels.every((c) => c instanceof Float32Array)) {
      throw new TypeError('kiln: source must be an AudioBuffer or a non-empty array of Float32Array');
    }
    const planar = channels as Float32Array[];
    const frames = planar[0].length;
    if (!planar.every((c) => c.length === frames)) {
      throw new RangeError('kiln: all channels must have the same length');
    }
    if (sampleRate === undefined || !Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xFFFF_FFFF) {
      throw new RangeError('kiln: sampleRate must be a positive integer');
    }
    const count = frames * planar.length;
    const ptr = e.kiln_alloc_f32(count) >>> 0;
    if (ptr === 0) throw new KilnError('OutOfMemory');
    try {
      if (count > 0) {
        const view = new Float32Array(e.memory.buffer, ptr, count);
        planar.forEach((c, i) => view.set(c, i * frames));
      }
      return fn(ptr, planar.length, frames, sampleRate);
    } finally {
      e.kiln_free_f32(ptr, count);
    }
  }

  const mp3: Mp3 = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_mp3_probe(ptr, len));
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(2));
        return {
          sampleRate,
          channels: Number(e.kiln_value(1)),
          samples,
          frames: Number(e.kiln_value(3)),
          minStart: Number(e.kiln_value(4)),
          duration: samples / sampleRate,
        };
      });
    },

    trim(input, options = {}) {
      return trimWith(e.kiln_mp3_probe, e.kiln_mp3_trim, input, options);
    },

    // タグなしの入力でも先頭を 529 に切り上げない(デコードでは先頭のデコーダ遅延も出力できるため)
    decode(input, options = {}) {
      return decodeWith(e.kiln_mp3_probe, e.kiln_mp3_decode, input, options);
    },

    toWav(input, options = {}) {
      const { format, dither } = formatOptions(options);
      return rangeWith(e.kiln_mp3_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_mp3_to_wav(ptr, len, s, t ?? 0n, t !== null, format, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    toFlac(input, options = {}) {
      const { bits, compression, dither } = flacOptions(options);
      return rangeWith(e.kiln_mp3_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_mp3_to_flac(ptr, len, s, t ?? 0n, t !== null, bits ?? 16, compression, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },
  };

  const wav: Wav = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_wav_probe(ptr, len));
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(3));
        return {
          sampleRate,
          channels: Number(e.kiln_value(1)),
          format: FORMATS[Number(e.kiln_value(2))],
          samples,
          duration: samples / sampleRate,
        };
      });
    },

    trim(input, options = {}) {
      return trimWith(e.kiln_wav_probe, e.kiln_wav_trim, input, options);
    },

    encode(source: AudioBufferLike | Float32Array[], options: WavFormatOptions & { sampleRate?: number } = {}) {
      const { format, dither } = formatOptions(options);
      return withPlanar(source, options, (ptr, nch, frames, sampleRate) => {
        check(e.kiln_wav_encode(ptr, nch, frames, sampleRate, format, dither));
        return takeOutput();
      });
    },

    // bitsPerSample を省くと、整数の WAV なら元のビット深度、浮動小数点なら 16(コアが決める)
    toFlac(input, options = {}) {
      const { bits, compression, dither } = flacOptions(options);
      return rangeWith(e.kiln_wav_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_wav_to_flac(ptr, len, s, t ?? 0n, t !== null, bits ?? 0, bits !== undefined, compression, dither));
        return { data: takeOutput() };
      });
    },
  };

  const flac: Flac = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_flac_probe(ptr, len));
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(3));
        return {
          sampleRate,
          channels: Number(e.kiln_value(1)),
          bitsPerSample: Number(e.kiln_value(2)),
          samples,
          frames: Number(e.kiln_value(4)),
          duration: samples / sampleRate,
        };
      });
    },

    decode(input, options = {}) {
      return decodeWith(e.kiln_flac_format, e.kiln_flac_decode, input, options);
    },

    toWav(input, options = {}) {
      const { format, dither } = formatOptions(options, null);
      return rangeWith(e.kiln_flac_format, input, options, (ptr, len, s, t) => {
        check(e.kiln_flac_to_wav(ptr, len, s, t ?? 0n, t !== null, Math.max(format, 0), format >= 0, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    trim(input, options = {}) {
      return rangeWith(e.kiln_flac_format, input, options, (ptr, len, s, t) => {
        check(e.kiln_flac_trim(ptr, len, s, t ?? 0n, t !== null));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    encode(source: AudioBufferLike | Float32Array[], options: FlacFormatOptions & { sampleRate?: number } = {}) {
      const { bits, compression, dither } = flacOptions(options);
      return withPlanar(source, options, (ptr, nch, frames, sampleRate) => {
        check(e.kiln_flac_encode(ptr, nch, frames, sampleRate, bits ?? 16, compression, dither));
        return takeOutput();
      });
    },
  };

  /** wasm の 3 値(0: なし、1: あり、2: 不明)を boolean か null にする */
  const tristate = (v: bigint): boolean | null => (v === 2n ? null : v === 1n);

  const ogg: Ogg = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_ogg_probe(ptr, len));
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(2));
        const inputSampleRate = Number(e.kiln_value(4));
        return {
          codec: e.kiln_value(3) === 1n ? 'opus' : 'vorbis',
          sampleRate,
          inputSampleRate: inputSampleRate === 0 ? null : inputSampleRate,
          channels: Number(e.kiln_value(1)),
          samples,
          duration: samples / sampleRate,
          preSkip: Number(e.kiln_value(5)),
          invalidPages: Number(e.kiln_value(6)),
          trimmable: e.kiln_value(7) === 1n,
        };
      });
    },

    trim(input, options = {}) {
      return trimWith(e.kiln_ogg_probe, e.kiln_ogg_trim, input, options);
    },
  };

  const m4a: M4a = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_m4a_probe(ptr, len));
        const audioSpecificConfig = takeOutput();
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(2));
        const alac = e.kiln_value(3) === 1n;
        const objectType = Number(e.kiln_value(4));
        const sbr = tristate(e.kiln_value(5));
        const ps = tristate(e.kiln_value(6));
        return {
          codec: alac ? 'alac' : 'aac',
          profile: alac ? null : ps === true ? 'hev2' : sbr === true ? 'he' : (AAC_PROFILES[objectType] ?? 'other'),
          objectType,
          sbr,
          ps,
          sampleRate,
          channels: Number(e.kiln_value(1)),
          bitsPerSample: alac ? Number(e.kiln_value(8)) : null,
          samples,
          duration: samples / sampleRate,
          encoderDelay: Number(e.kiln_value(7)),
          audioSpecificConfig,
          trimmable: e.kiln_value(9) === 1n,
        };
      });
    },

    trim(input, options = {}) {
      return trimWith(e.kiln_m4a_probe, e.kiln_m4a_trim, input, options);
    },
  };

  const aac: Aac = {
    probe(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_aac_probe(ptr, len));
        const sampleRate = Number(e.kiln_value(0));
        const samples = Number(e.kiln_value(2));
        return {
          // ADTS のヘッダの profile は 0〜3(オブジェクトタイプ 1〜4)なので、必ずどれかになる
          profile: AAC_PROFILES[Number(e.kiln_value(4)) + 1] as AacInfo['profile'],
          mpegVersion: Number(e.kiln_value(5)),
          sbr: null,
          sampleRate,
          channels: Number(e.kiln_value(1)),
          frames: Number(e.kiln_value(3)),
          samples,
          duration: samples / sampleRate,
          trimmable: e.kiln_value(6) === 1n,
          sbrTrimmable: e.kiln_value(7) === 1n,
        };
      });
    },

    frames(input, limit) {
      if (!Number.isInteger(limit) || limit < 0 || limit > 0xFFFF) throw new RangeError('kiln: limit must be an integer from 0 to 65535');
      return withInput(input, (ptr, len) => {
        check(e.kiln_aac_frames(ptr, len, limit));
        const bytes = takeOutput();
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        return Array.from({ length: bytes.byteLength / 8 }, (_, i) => ({ offset: view.getUint32(i * 8, true), length: view.getUint32(i * 8 + 4, true) }));
      });
    },

    trim(input, options) {
      const { sbr, ...range } = options;
      return rangeWith(e.kiln_aac_probe, input, range, (ptr, len, s, t) => {
        check(e.kiln_aac_trim(ptr, len, s, t ?? 0n, t !== null, sbr));
        return { data: takeOutput() };
      }, sbr ? 2 : 1);
    },
  };

  // kiln.Format(src/root.zig)の番号と並びを合わせる
  const DETECT_FORMATS: Format[] = ['mp3', 'wav', 'flac', 'ogg', 'm4a', 'aac'];

  return {
    version: decoder.decode(bytesAt(e.kiln_version_ptr(), e.kiln_version_len())),
    detect(input) {
      return withInput(input, (ptr, len) => {
        check(e.kiln_detect(ptr, len));
        if (Number(e.kiln_value(0)) === 0) return null;
        return { format: DETECT_FORMATS[Number(e.kiln_value(1))], sampleRate: Number(e.kiln_value(2)) || null };
      });
    },
    mp3,
    wav,
    flac,
    ogg,
    m4a,
    aac,
    exports: instance.exports,
  };
}
