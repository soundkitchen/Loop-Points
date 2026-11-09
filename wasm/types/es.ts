// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(DOM の型がない環境、lib: ES2022 だけ)。tsc -p wasm/types/tsconfig.es.json
import { load, type Kiln } from '../kiln.js';

export async function usage(wasm: Uint8Array<ArrayBuffer>, bytes: Uint8Array): Promise<number> {
  const k: Kiln = await load(wasm);
  await load('file:///kiln.wasm');
  return k.wav.encode([new Float32Array(2)], { sampleRate: 8000 }).length + k.mp3.probe(bytes).samples;
}
