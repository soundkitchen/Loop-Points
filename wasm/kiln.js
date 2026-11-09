// SPDX-License-Identifier: MIT
// K!LN の JS ラッパー。kiln.wasm を読み込み、export 関数を JS から使いやすくする。

/** WAV のサンプル形式の名前。並びは kiln.pcm.Format と同じ(wasm とは番号でやり取りする) */
const FORMATS = ['u8', 'i16', 'i24', 'i32', 'f32', 'f64'];

/** K!LN のコアが返したエラー。`name` に加えて `code` にコアのエラー名(`NotMp3` など)が入る */
export class KilnError extends Error {
  constructor(code) {
    super(`kiln: ${code}`);
    this.name = 'KilnError';
    this.code = code;
  }
}

/**
 * kiln.wasm を読み込んで初期化する。
 * @param {string | { href: string } | ArrayBuffer | ArrayBufferView} source wasm の URL(文字列か、URL のように
 *   `href` を持つもの)、またはバイト列
 */
export async function load(source = new URL('./kiln.wasm', import.meta.url)) {
  let instance;
  const url = typeof source === 'string' ? source : typeof source?.href === 'string' ? source.href : null;
  if (url !== null) {
    const response = await fetch(url);
    // 404 の HTML などを wasm として解釈して分かりにくいエラーにならないよう、先に確認する
    if (!response.ok) {
      throw new Error(`failed to fetch ${url}: ${response.status} ${response.statusText}`);
    }
    // ダウンロードしながらコンパイルする。サーバが application/wasm を返さない場合は
    // instantiateStreaming が失敗するので、バイト列での読み込みに切り替える
    try {
      ({ instance } = await WebAssembly.instantiateStreaming(response.clone(), {}));
    } catch {
      ({ instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {}));
    }
  } else {
    ({ instance } = await WebAssembly.instantiate(source, {}));
  }
  const e = instance.exports;
  const decoder = new TextDecoder();
  // export 関数が返すポインタと長さは wasm の i32 で、JS には符号付きで見える
  // (2GiB 以上のアドレスや、長さ 0 の確保が返す 0xFFFFFFFF が負になる)ため、符号なしに直す。
  // memory が伸びると以前のビューは使えなくなるため、読み書きのたびに作り直す
  const bytesAt = (ptr, len) => {
    len >>>= 0;
    return len === 0 ? new Uint8Array(0) : new Uint8Array(e.memory.buffer, ptr >>> 0, len);
  };

  /**
   * 入力を linear memory に写して fn(ptr, len) を呼び、終わったら解放する。
   * Uint8Array 以外の TypedArray や DataView は、要素の値ではなくバイト列として扱う
   */
  function withInput(input, fn) {
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

  function check(ok) {
    if (!ok) throw new KilnError(decoder.decode(bytesAt(e.kiln_error_ptr(), e.kiln_error_len())));
  }

  /** 秒をサンプル位置にする(切り捨て)。浮動小数点の誤差で 1 少なくならないよう、わずかに足す */
  function toSamples(seconds, sampleRate, label) {
    if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) {
      throw new RangeError(`kiln: ${label} must be a non-negative number of seconds`);
    }
    return BigInt(Math.floor(seconds * sampleRate + 1e-6));
  }

  /** サンプル位置を wasm の u64 引数として渡せる BigInt にする(範囲外は RangeError) */
  function toSampleIndex(n, label) {
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

  /**
   * トリムの共通処理。位置は秒(start / end)かサンプル数(startSample / endSample)で指定する。
   * probeExport は秒を位置に直すためのサンプルレートを kiln_value(0) に置く関数、
   * trimExport は実際に切り出した区間を kiln_value(0, 1) に、サンプルレートを kiln_value(2) に置く関数
   */
  function trimWith(probeExport, trimExport, input, options) {
    return rangeWith(probeExport, input, options, (ptr, len, s, t) => {
      check(trimExport(ptr, len, s, t ?? 0n, t !== null));
      return { data: takeOutput() };
    });
  }

  /**
   * 区間を指定する処理の共通部分。秒(start / end)かサンプル数(startSample / endSample)を
   * サンプル位置の BigInt にして fn(ptr, len, start, end | null) を呼ぶ。fn は実際の区間を kiln_value(0, 1) に、
   * サンプルレートを kiln_value(2) に置く export を呼び、戻り値に区間を足して返す
   */
  function rangeWith(probeExport, input, options, fn) {
    const { start, end, startSample, endSample } = options;
    if (start !== undefined && startSample !== undefined) {
      throw new TypeError('kiln: specify either start or startSample, not both');
    }
    if (end !== undefined && endSample !== undefined) {
      throw new TypeError('kiln: specify either end or endSample, not both');
    }
    return withInput(input, (ptr, len) => {
      // 秒を位置に直すときだけ、サンプルレートを知るために先に解析する
      let sampleRate;
      if (start !== undefined || end !== undefined) {
        check(probeExport(ptr, len));
        sampleRate = Number(e.kiln_value(0));
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
   * サンプル形式とディザの名前を wasm に渡す番号にする。fallback は format を省いたときの形式で、
   * null なら format は -1(コアが決める)
   */
  function formatOptions(options, fallback = 'i16') {
    const name = options.format ?? fallback;
    const format = name === null ? -1 : FORMATS.indexOf(name);
    if (name !== null && format < 0) throw new RangeError(`kiln: unknown format '${options.format}'`);
    const dither = { tpdf: 1, none: 0 }[options.dither ?? 'tpdf'];
    if (dither === undefined) throw new RangeError(`kiln: unknown dither '${options.dither}'`);
    return { format, dither };
  }

  /**
   * デコードの共通処理。decodeExport はチャンネルごとに並べた f32 を出力に、kiln_value の 0: start、1: end、
   * 2: サンプルレート、3: チャンネル数、4: 復号できなかったフレームの数を置く関数
   */
  function decodeWith(probeExport, decodeExport, input, options) {
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
   * FLAC の書き出しの指定を wasm に渡す値にする。defaultBits は bitsPerSample を省いたときの値で、
   * null なら bits は null(コアが決める)。利用者が渡した bitsPerSample は必ず 4〜32 の整数か確かめる
   */
  function flacOptions(options, defaultBits = 16) {
    if (options.bitsPerSample !== undefined
      && !(Number.isInteger(options.bitsPerSample) && options.bitsPerSample >= 4 && options.bitsPerSample <= 32)) {
      throw new RangeError('kiln: bitsPerSample must be an integer from 4 to 32');
    }
    const bits = options.bitsPerSample ?? defaultBits;
    const compression = options.compression ?? 5;
    if (!(Number.isInteger(compression) && compression >= 0 && compression <= 8)) {
      throw new RangeError('kiln: compression must be an integer from 0 to 8');
    }
    const { dither } = formatOptions({ dither: options.dither });
    return { bits, compression, dither };
  }

  /**
   * AudioBuffer か Float32Array の配列を、チャンネルごとに続けて linear memory に写して
   * fn(ptr, channels, frames, sampleRate) を呼び、終わったら解放する
   */
  function withPlanar(source, options, fn) {
    let channels = source;
    let sampleRate = options.sampleRate;
    if (source && typeof source.getChannelData === 'function') {
      channels = Array.from({ length: source.numberOfChannels }, (_, i) => source.getChannelData(i));
      sampleRate ??= source.sampleRate;
    }
    if (!Array.isArray(channels) || channels.length === 0 || !channels.every((c) => c instanceof Float32Array)) {
      throw new TypeError('kiln: source must be an AudioBuffer or a non-empty array of Float32Array');
    }
    const frames = channels[0].length;
    if (!channels.every((c) => c.length === frames)) {
      throw new RangeError('kiln: all channels must have the same length');
    }
    if (!Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xFFFF_FFFF) {
      throw new RangeError('kiln: sampleRate must be a positive integer');
    }
    const count = frames * channels.length;
    const ptr = e.kiln_alloc_f32(count) >>> 0;
    if (ptr === 0) throw new KilnError('OutOfMemory');
    try {
      if (count > 0) {
        const view = new Float32Array(e.memory.buffer, ptr, count);
        channels.forEach((c, i) => view.set(c, i * frames));
      }
      return fn(ptr, channels.length, frames, sampleRate);
    } finally {
      e.kiln_free_f32(ptr, count);
    }
  }

  /** 出力のバイト列をコピーして解放する(linear memory の中身は次の呼び出しで変わるため) */
  function takeOutput() {
    const data = bytesAt(e.kiln_output_ptr(), e.kiln_output_len()).slice();
    e.kiln_output_free();
    return data;
  }

  const mp3 = {
    /**
     * MP3 を解析する。
     * @param {ArrayBufferLike | ArrayBufferView} input MP3 ファイル全体
     * @returns {{ sampleRate: number, channels: number, samples: number, frames: number,
     *             minStart: number, duration: number }}
     *   samples はタイムラインの長さ、minStart はトリムで指定できる先頭の最小値(サンプル数)
     */
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

    /**
     * MP3 を再エンコードせずにトリムする。範囲外の指定は丸める。
     * 位置は秒(start / end)かサンプル数(startSample / endSample)で指定する。end を省くと末尾まで。
     * @param {ArrayBufferLike | ArrayBufferView} input MP3 ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number }}
     *   data はトリムした MP3。startSample / endSample(秒は start / end)は実際に切り出した区間
     */
    trim(input, options = {}) {
      return trimWith(e.kiln_mp3_probe, e.kiln_mp3_trim, input, options);
    },

    /**
     * MP3 をデコードする。位置の指定は trim と同じ(タグなしの入力でも先頭を 529 に切り上げない)。
     * @param {ArrayBufferLike | ArrayBufferView} input MP3 ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ channels: Float32Array[], sampleRate: number, startSample: number, endSample: number, start: number, end: number,
     *             invalidFrames: number }}
     *   channels はチャンネルごとの PCM(AudioBuffer の getChannelData と同じ並び)。invalidFrames は
     *   復号できなかった(無音にした)フレームの数
     */
    decode(input, options = {}) {
      return decodeWith(e.kiln_mp3_probe, e.kiln_mp3_decode, input, options);
    },

    /**
     * MP3 をデコードして WAV にする。位置の指定は decode と同じ。
     * @param {ArrayBufferLike | ArrayBufferView} input MP3 ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint,
     *           format?: string, dither?: 'tpdf' | 'none' }} options format の既定は 'i16'、dither の既定は 'tpdf'
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number, invalidFrames: number }}
     */
    toWav(input, options = {}) {
      const { format, dither } = formatOptions(options);
      return rangeWith(e.kiln_mp3_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_mp3_to_wav(ptr, len, s, t ?? 0n, t !== null, format, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    /**
     * MP3 をデコードして FLAC にする。位置の指定と戻り値は toWav と同じ。
     * @param {ArrayBufferLike | ArrayBufferView} input MP3 ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint,
     *           bitsPerSample?: number, compression?: number, dither?: 'tpdf' | 'none' }} options
     *   bitsPerSample の既定は 16、compression の既定は 5、dither の既定は 'tpdf'
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number, invalidFrames: number }}
     */
    toFlac(input, options = {}) {
      const { bits, compression, dither } = flacOptions(options);
      return rangeWith(e.kiln_mp3_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_mp3_to_flac(ptr, len, s, t ?? 0n, t !== null, bits, compression, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },
  };

  const wav = {
    /**
     * WAV を解析する。
     * @param {ArrayBufferLike | ArrayBufferView} input WAV ファイル全体
     * @returns {{ sampleRate: number, channels: number, format: string, samples: number, duration: number }}
     *   format はサンプル形式('u8' / 'i16' / 'i24' / 'i32' / 'f32' / 'f64')
     */
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

    /**
     * WAV をサンプル単位で切り出す(元の形式のまま)。範囲外の指定は丸める。
     * 位置の指定と戻り値は mp3.trim と同じ
     * @param {ArrayBufferLike | ArrayBufferView} input WAV ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number }}
     */
    trim(input, options = {}) {
      return trimWith(e.kiln_wav_probe, e.kiln_wav_trim, input, options);
    },

    /**
     * PCM を WAV にする。decodeAudioData が返す AudioBuffer か、チャンネルごとの Float32Array の配列を渡す。
     * @param {AudioBuffer | Float32Array[]} source どのチャンネルも同じ長さ
     * @param {{ sampleRate?: number, format?: string, dither?: 'tpdf' | 'none' }} options
     *   sampleRate は AudioBuffer なら省ける。format の既定は 'i16'、dither の既定は 'tpdf'(整数形式のときだけ効く)
     * @returns {Uint8Array} WAV ファイル
     */
    encode(source, options = {}) {
      const { format, dither } = formatOptions(options);
      return withPlanar(source, options, (ptr, nch, frames, sampleRate) => {
        check(e.kiln_wav_encode(ptr, nch, frames, sampleRate, format, dither));
        return takeOutput();
      });
    },

    /**
     * WAV の区間を FLAC にする。位置の指定と戻り値は trim と同じ。整数の WAV はビット深度を変えなければ可逆。
     * @param {ArrayBufferLike | ArrayBufferView} input WAV ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint,
     *           bitsPerSample?: number, compression?: number, dither?: 'tpdf' | 'none' }} options
     *   bitsPerSample の既定は、整数の WAV なら元のビット深度、浮動小数点なら 16。compression の既定は 5
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number }}
     */
    toFlac(input, options = {}) {
      const { bits, compression, dither } = flacOptions(options, null);
      return rangeWith(e.kiln_wav_probe, input, options, (ptr, len, s, t) => {
        check(e.kiln_wav_to_flac(ptr, len, s, t ?? 0n, t !== null, bits ?? 0, bits !== null, compression, dither));
        return { data: takeOutput() };
      });
    },
  };

  const flac = {
    /**
     * FLAC を解析する。
     * @param {ArrayBufferLike | ArrayBufferView} input FLAC ファイル全体
     * @returns {{ sampleRate: number, channels: number, bitsPerSample: number, samples: number, frames: number,
     *             duration: number }}
     */
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

    /**
     * FLAC をデコードする。位置の指定と戻り値は mp3.decode と同じ。
     * channels の値は整数のサンプルを 2^(bitsPerSample - 1) で割ったもの
     * @param {ArrayBufferLike | ArrayBufferView} input FLAC ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ channels: Float32Array[], sampleRate: number, startSample: number, endSample: number, start: number, end: number,
     *             invalidFrames: number }}
     */
    decode(input, options = {}) {
      return decodeWith(e.kiln_flac_format, e.kiln_flac_decode, input, options);
    },

    /**
     * FLAC をデコードして WAV にする。位置の指定は decode と同じ。format を省くとビット深度を保つ形式
     * (8bit 以下は 'u8'、16bit 以下は 'i16'、24bit 以下は 'i24'、それより多ければ 'i32')で、元の PCM のまま。
     * @param {ArrayBufferLike | ArrayBufferView} input FLAC ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint,
     *           format?: string, dither?: 'tpdf' | 'none' }} options dither の既定は 'tpdf'(ビット数を減らすときだけ効く)
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number, invalidFrames: number }}
     */
    toWav(input, options = {}) {
      const { format, dither } = formatOptions(options, null);
      return rangeWith(e.kiln_flac_format, input, options, (ptr, len, s, t) => {
        check(e.kiln_flac_to_wav(ptr, len, s, t ?? 0n, t !== null, Math.max(format, 0), format >= 0, dither));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    /**
     * FLAC を FLAC のまま切り出す(可逆。区間の先頭と末尾にかかるフレームだけを作り直す)。範囲外の指定は丸める。
     * 位置の指定は mp3.trim と同じ。タグと画像は残し、シークテーブル・CUE シート・PADDING は捨てる
     * @param {ArrayBufferLike | ArrayBufferView} input FLAC ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number, invalidFrames: number }}
     *   invalidFrames は、区間にかかった壊れたフレーム(無音として作り直した)の数
     */
    trim(input, options = {}) {
      return rangeWith(e.kiln_flac_format, input, options, (ptr, len, s, t) => {
        check(e.kiln_flac_trim(ptr, len, s, t ?? 0n, t !== null));
        return { data: takeOutput(), invalidFrames: Number(e.kiln_value(4)) };
      });
    },

    /**
     * PCM を FLAC にする。decodeAudioData が返す AudioBuffer か、チャンネルごとの Float32Array の配列(1〜8 チャンネル)を渡す。
     * @param {AudioBuffer | Float32Array[]} source どのチャンネルも同じ長さ
     * @param {{ sampleRate?: number, bitsPerSample?: number, compression?: number, dither?: 'tpdf' | 'none' }} options
     *   sampleRate は AudioBuffer なら省ける。bitsPerSample の既定は 16、compression の既定は 5(0〜8。flac の -0〜-8)
     * @returns {Uint8Array} FLAC ファイル
     */
    encode(source, options = {}) {
      const { bits, compression, dither } = flacOptions(options);
      return withPlanar(source, options, (ptr, nch, frames, sampleRate) => {
        check(e.kiln_flac_encode(ptr, nch, frames, sampleRate, bits, compression, dither));
        return takeOutput();
      });
    },
  };

  return {
    /** ライブラリのバージョン */
    version: decoder.decode(bytesAt(e.kiln_version_ptr(), e.kiln_version_len())),
    /** MP3 の解析、トリム、デコード(PCM、WAV、FLAC) */
    mp3,
    /** WAV の解析、切り出し、書き出し(WAV と FLAC) */
    wav,
    /** FLAC の解析、切り出し、デコード、書き出し */
    flac,
    /** 生の export 関数(低レベル API) */
    exports: e,
  };
}
