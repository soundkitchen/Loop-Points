// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(DOM の型がない環境、lib: ES2022 だけ)。tsc -p wasm/types/tsconfig.es.json
import { load, type Kiln } from '../kiln.js';

export async function usage(wasm: Uint8Array<ArrayBuffer>, bytes: Uint8Array): Promise<number> {
  const k: Kiln = await load(wasm);
  await load('file:///kiln.wasm');
  const f = k.flac.decode(bytes, { startSample: 10n });
  const w: Uint8Array<ArrayBuffer> = k.flac.toWav(bytes, { end: 1, format: 'i24' }).data;
  const bits: number = k.flac.probe(bytes).bitsPerSample;
  // @ts-expect-error flac に trim はまだない
  k.flac.trim(bytes);
  return k.wav.encode([new Float32Array(2)], { sampleRate: 8000 }).length + k.mp3.probe(bytes).samples + f.channels.length + w.length + bits;
}
