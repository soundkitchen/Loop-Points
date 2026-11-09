// K!LN の JS ラッパー。kiln.wasm を読み込み、export 関数を JS から使いやすくする。

/** K!LN のコアが返したエラー。`name` に加えて `code` にコアのエラー名(`NotMp3` など)が入る */
/** WAV のサンプル形式の名前。並びは kiln.pcm.Format と同じ(wasm とは番号でやり取りする) */
const FORMATS = ['u8', 'i16', 'i24', 'i32', 'f32', 'f64'];

export class KilnError extends Error {
  constructor(code) {
    super(`kiln: ${code}`);
    this.name = 'KilnError';
    this.code = code;
  }
}

/**
 * kiln.wasm を読み込んで初期化する。
 * @param {URL | string | BufferSource} source wasm の URL、またはバイト列
 */
export async function load(source = new URL('./kiln.wasm', import.meta.url)) {
  let instance;
  if (source instanceof URL || typeof source === 'string') {
    const response = await fetch(source);
    // 404 の HTML などを wasm として解釈して分かりにくいエラーにならないよう、先に確認する
    if (!response.ok) {
      throw new Error(`failed to fetch ${source}: ${response.status} ${response.statusText}`);
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
      check(trimExport(ptr, len, s, t ?? 0n, t !== null));
      const r0 = Number(e.kiln_value(0));
      const r1 = Number(e.kiln_value(1));
      sampleRate = Number(e.kiln_value(2));
      return { data: takeOutput(), startSample: r0, endSample: r1, start: r0 / sampleRate, end: r1 / sampleRate };
    });
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
     * @param {BufferSource} input MP3 ファイル全体
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
     * @param {BufferSource} input MP3 ファイル全体
     * @param {{ start?: number, end?: number, startSample?: number | bigint, endSample?: number | bigint }} options
     * @returns {{ data: Uint8Array, startSample: number, endSample: number, start: number, end: number }}
     *   data はトリムした MP3。startSample / endSample(秒は start / end)は実際に切り出した区間
     */
    trim(input, options = {}) {
      return trimWith(e.kiln_mp3_probe, e.kiln_mp3_trim, input, options);
    },
  };

  const wav = {
    /**
     * WAV を解析する。
     * @param {BufferSource} input WAV ファイル全体
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
     * @param {BufferSource} input WAV ファイル全体
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
      const format = FORMATS.indexOf(options.format ?? 'i16');
      if (format < 0) throw new RangeError(`kiln: unknown format '${options.format}'`);
      const dither = { tpdf: 1, none: 0 }[options.dither ?? 'tpdf'];
      if (dither === undefined) throw new RangeError(`kiln: unknown dither '${options.dither}'`);

      const count = frames * channels.length;
      const ptr = e.kiln_alloc_f32(count) >>> 0;
      if (ptr === 0) throw new KilnError('OutOfMemory');
      try {
        if (count > 0) {
          const view = new Float32Array(e.memory.buffer, ptr, count);
          channels.forEach((c, i) => view.set(c, i * frames));
        }
        check(e.kiln_wav_encode(ptr, channels.length, frames, sampleRate, format, dither));
        return takeOutput();
      } finally {
        e.kiln_free_f32(ptr, count);
      }
    },
  };

  return {
    /** ライブラリのバージョン */
    version: decoder.decode(bytesAt(e.kiln_version_ptr(), e.kiln_version_len())),
    /** MP3 の解析とトリム */
    mp3,
    /** WAV の解析、切り出し、書き出し */
    wav,
    /** 生の export 関数(低レベル API) */
    exports: e,
  };
}
