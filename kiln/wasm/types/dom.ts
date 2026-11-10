// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(ブラウザのメインスレッド、lib: DOM)。tsc -p wasm/types/tsconfig.dom.json(npm run kiln:test で動く)
// Loop Points の tsc は skipLibCheck で .d.ts を検査しないので、すべての API をここで一度は使う
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

// FLAC、Ogg、m4a、aac の API
export async function formats(wasm: Uint8Array<ArrayBuffer>, bytes: Uint8Array): Promise<number> {
  const k: Kiln = await load(wasm);
  const f = k.flac.decode(bytes, { startSample: 10n });
  const w: Uint8Array<ArrayBuffer> = k.flac.toWav(bytes, { end: 1, format: 'i24' }).data;
  const bits: number = k.flac.probe(bytes).bitsPerSample;
  const fe: Uint8Array<ArrayBuffer> = k.flac.encode([new Float32Array(2)], { sampleRate: 8000, bitsPerSample: 24, compression: 8 });
  const wf = k.wav.toFlac(bytes, { startSample: 0, compression: 0 }).data;
  const mf = k.mp3.toFlac(bytes, { end: 1, dither: 'none' }).invalidFrames;
  const ft: Uint8Array<ArrayBuffer> = k.flac.trim(bytes, { start: 1, endSample: 5n }).data;
  // @ts-expect-error trim に書き出しの指定はない
  k.flac.trim(bytes, { compression: 5 });
  // @ts-expect-error Float32Array[] のときは sampleRate が要る
  k.flac.encode([new Float32Array(2)]);
  const o = k.ogg.probe(bytes);
  const codec: 'vorbis' | 'opus' = o.codec;
  const rate: number | null = o.inputSampleRate;
  const m = k.m4a.probe(bytes);
  const sbr: boolean | null = m.sbr;
  const asc: Uint8Array<ArrayBuffer> = m.audioSpecificConfig;
  const a = k.aac.probe(bytes);
  const none: null = a.sbr;
  // @ts-expect-error aac の profile に HE-AAC はない(ヘッダに書けない)
  const he: typeof a.profile = 'he';
  return f.channels.length + w.length + bits + fe.length + wf.length + mf + ft.length +
    codec.length + (rate ?? 0) + Number(sbr) + asc.length + Number(none) + he.length + m.samples + a.frames + o.preSkip;
}

// 誤った使い方は型エラーになる
export function misuse(k: Kiln, bytes: Uint8Array) {
  // @ts-expect-error URL からは読まない(バイト列だけ)
  load(new URL('https://example.com/kiln.wasm'));
  // @ts-expect-error wasm のバイト列は省けない
  load();
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
