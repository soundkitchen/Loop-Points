// K!LN の JS ラッパー。kiln.wasm を読み込み、export 関数を JS から使いやすくする。

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

  return {
    /** ライブラリのバージョン */
    version: decoder.decode(new Uint8Array(e.memory.buffer, e.kiln_version_ptr(), e.kiln_version_len())),
    /** 生の export 関数(低レベル API) */
    exports: e,
  };
}
