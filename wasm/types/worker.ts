// SPDX-License-Identifier: MIT
// kiln.d.ts の型検査(Worker、lib: WebWorker)。tsc -p wasm/types/tsconfig.worker.json
import { load, KilnError } from '../kiln.js';

declare const self: DedicatedWorkerGlobalScope;
const kiln = load(new URL('../kiln.wasm', import.meta.url));
self.onmessage = async (ev: MessageEvent<{ bytes: ArrayBuffer; start: number; end: number }>) => {
  try {
    const { data } = (await kiln).mp3.trim(ev.data.bytes, { start: ev.data.start, end: ev.data.end });
    self.postMessage({ data }, [data.buffer]);
  } catch (e) {
    self.postMessage({ error: e instanceof KilnError ? e.code : String(e) });
  }
};
