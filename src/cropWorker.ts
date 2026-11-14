// クロップの書き出しの kiln の処理 (cropJob.ts) を動かす Worker。デコードやエンコードに数秒かかることがあり、
// メインスレッドで動かすとその間画面が固まるため。kiln の wasm は、このチャンクにも埋め込まれる (kilnLoader.ts)
import { KilnError } from '../kiln/wasm/kiln';
import { runCropJob, type CropJob } from './cropJob';
import { loadKiln, resetKiln } from './kilnLoader';

export interface CropRequest { id: number; job: CropJob }
export type CropReply = { id: number; result: ReturnType<typeof runCropJob> } | { id: number; error: string };

addEventListener('message', (e: MessageEvent<CropRequest>) => {
  const { id, job } = e.data;
  loadKiln().then(
    (k) => {
      const result = runCropJob(k, job);
      postMessage({ id, result } satisfies CropReply, { transfer: [result.data.buffer] });
    },
  ).catch((err: unknown) => {
    // kiln が返したエラー (KilnError) のあとは、そのまま使い続けられる。それ以外は、wasm が途中で止まったもの
    // (メモリが足りないときなど。Ogg Vorbis のエンコードは、エラーを返せずに止まる) がありうるので、作り直す
    if (!(err instanceof KilnError)) resetKiln();
    postMessage({ id, error: err instanceof Error ? err.message : String(err) } satisfies CropReply);
  });
});
