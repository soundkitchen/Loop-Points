// K!LN の JS ラッパー。kiln.wasm を読み込み、export 関数を JS から使いやすくする。

/**
 * kiln.wasm を読み込んで初期化する。
 * @param {URL | string | BufferSource} source wasm の URL、またはバイト列
 */
export async function load(source = new URL('./kiln.wasm', import.meta.url)) {
  const bytes =
    source instanceof URL || typeof source === 'string'
      ? await (await fetch(source)).arrayBuffer()
      : source;
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  const decoder = new TextDecoder();

  return {
    /** ライブラリのバージョン */
    version: decoder.decode(new Uint8Array(e.memory.buffer, e.kiln_version_ptr(), e.kiln_version_len())),
    /** 生の export 関数(低レベル API) */
    exports: e,
  };
}
