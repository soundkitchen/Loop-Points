// SPDX-License-Identifier: MIT
// K!LN の JS ラッパー(kiln.js)の型定義。TypeScript 5.7 以降(型引数付きの TypedArray を使う)。
// ES の標準の型だけを使い、DOM / WebWorker の型(BufferSource、URL、WebAssembly など)には頼らない。
// 変えたら wasm/types/ の型検査を通す(docs/architecture.md §2.3)。

/**
 * kiln のコアが返すエラーの名前。wasm/main.zig の `KilnError` と同じ一覧にする(足したら両方を直す)。
 * - `NotMp3` / `NotWav` / `NotFlac`: その形式のファイルではない
 * - `UnsupportedFormat`: 扱えない種類(MPEG-2 の MP3、RF64 や圧縮形式の WAV、Ogg FLAC など)
 * - `InvalidWav`: WAV が壊れている(`fmt ` / `data` チャンクがない、値が不正)
 * - `InvalidFlac`: FLAC が壊れている(STREAMINFO がない・先頭にない、メタデータブロックの長さが不正など)
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
  | 'EmptyRange'
  | 'TooLarge'
  | 'OutOfMemory'
  | 'InvalidOptions'
  | 'InternalError';

/** kiln のコアが返したエラー。`code` にエラーの名前が入る */
export class KilnError extends Error {
  constructor(code: KilnErrorCode);
  readonly name: 'KilnError';
  readonly code: KilnErrorCode;
}

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

/** `wav.encode` / `flac.encode` が受け取る PCM。`AudioBuffer` はこの形を満たす(Worker の型にない AudioBuffer の代わり) */
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
  /** デコードして WAV にする。`format` を省くとビット深度を保つ形式で、元の PCM のまま */
  toWav(
    input: BytesInput,
    options?: RangeOptions & WavFormatOptions,
  ): RangeResult & { data: Uint8Array<ArrayBuffer>; invalidFrames: number };
  /** AudioBuffer(や同じ形のもの。1〜8 チャンネル)を FLAC にする。`sampleRate` を省くと AudioBuffer のもの */
  encode(source: AudioBufferLike, options?: FlacFormatOptions & { sampleRate?: number }): Uint8Array<ArrayBuffer>;
  /** チャンネルごとの PCM を FLAC にする。どのチャンネルも同じ長さで、`sampleRate` は必須 */
  encode(source: Float32Array[], options: FlacFormatOptions & { sampleRate: number }): Uint8Array<ArrayBuffer>;
}

export interface Kiln {
  /** ライブラリのバージョン */
  readonly version: string;
  readonly mp3: Mp3;
  readonly wav: Wav;
  readonly flac: Flac;
  /** 生の export 関数(低レベル API。WebAssembly.Exports) */
  readonly exports: Record<string, unknown>;
}

/** wasm の URL。文字列か、URL のように `href` を持つもの(fetch する) */
export type WasmUrl = string | { readonly href: string };

/** wasm のバイト列(WebAssembly.instantiate に渡せるもの) */
export type WasmBytes = ArrayBuffer | ArrayBufferView<ArrayBuffer>;

/**
 * kiln.wasm を読み込んで初期化する。
 * @param source wasm の URL(fetch する)、またはバイト列。省くと kiln.js と同じ場所の kiln.wasm
 */
export function load(source?: WasmUrl | WasmBytes): Promise<Kiln>;
