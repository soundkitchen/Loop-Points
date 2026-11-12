// クロップの書き出しの kiln の処理 (cropJob.ts) を動かす Worker。デコードやエンコードに数秒かかることがあり、
// メインスレッドで動かすとその間画面が固まるため。kiln の wasm は、このチャンクにも埋め込まれる (kilnLoader.ts)
import { runCropJob, type CropJob } from './cropJob';
import { loadKiln } from './kilnLoader';

export interface CropRequest { id: number; job: CropJob }
export type CropReply = { id: number; result: ReturnType<typeof runCropJob> } | { id: number; error: string };

addEventListener('message', (e: MessageEvent<CropRequest>) => {
  const { id, job } = e.data;
  loadKiln().then(
    (k) => {
      const result = runCropJob(k, job);
      postMessage({ id, result } satisfies CropReply, { transfer: [result.data.buffer] });
    },
  ).catch((err: unknown) => postMessage({ id, error: err instanceof Error ? err.message : String(err) } satisfies CropReply));
});
