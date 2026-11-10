// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(DOM の型がない環境、lib: ES2022 だけ)。tsc -p wasm/types/tsconfig.es.json
import { load, type Kiln } from '../kiln.js';

export async function usage(wasm: Uint8Array<ArrayBuffer>, bytes: Uint8Array): Promise<number> {
  const k: Kiln = await load(wasm);
  await load('file:///kiln.wasm');
  // @ts-expect-error wasm の URL かバイト列は省けない
  await load();
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
  return k.wav.encode([new Float32Array(2)], { sampleRate: 8000 }).length + k.mp3.probe(bytes).samples + f.channels.length + w.length + bits + fe.length + wf.length + mf + ft.length;
}
