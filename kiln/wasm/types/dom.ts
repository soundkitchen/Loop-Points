// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(ブラウザのメインスレッド、lib: DOM)。tsc -p wasm/types/tsconfig.dom.json
import { load, KilnError, type KilnErrorCode, type Kiln } from '../kiln.js';

export async function usage(bytes: Uint8Array, wasm: ArrayBuffer, buf: AudioBuffer) {
  const k: Kiln = await load(wasm);
  const info = k.mp3.probe(bytes);
  const t = k.mp3.trim(bytes, { start: 1.5, end: info.duration });
  const d = k.mp3.decode(bytes, { startSample: 100n, endSample: 2000 });
  const ch: Float32Array[] = d.channels;
  const w = k.mp3.toWav(bytes, { start: 0, format: 'f32', dither: 'none' });
  const wf: string = k.wav.probe(w.data).format;
  k.wav.trim(w.data, { end: 1 });
  const e1 = k.wav.encode(buf, { format: 'i16' });
  const e2 = k.wav.encode([new Float32Array(4)], { sampleRate: 44100 });
  // 結果はそのまま Blob に渡せる
  const blob = new Blob([t.data, e1, e2, w.data], { type: 'audio/mpeg' });
  // SharedArrayBuffer や DataView も入力にできる
  k.mp3.probe(new DataView(new SharedArrayBuffer(8)));
  try {
    k.wav.trim(bytes);
  } catch (e) {
    if (e instanceof KilnError) {
      const c: KilnErrorCode = e.code;
      if (c === 'InternalError') throw e;
    }
  }
  return [t.startSample, ch, wf, d.invalidFrames, w.invalidFrames, k.version, blob];
}

// 誤った使い方は型エラーになる
export function misuse(k: Kiln, bytes: Uint8Array) {
  // @ts-expect-error URL からは読まない(バイト列だけ)
  load(new URL('https://example.com/kiln.wasm'));
  // @ts-expect-error start と startSample は同時に指定できない
  k.mp3.trim(bytes, { start: 1, startSample: 2 });
  // @ts-expect-error 未知のサンプル形式
  k.mp3.toWav(bytes, { format: 'i8' });
  // @ts-expect-error Float32Array[] のときは sampleRate が要る
  k.wav.encode([new Float32Array(4)]);
  // @ts-expect-error code は決まった名前だけ
  const c: KilnErrorCode = 'Oops';
  return c;
}
