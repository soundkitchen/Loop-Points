// kiln (kiln/) の wasm を読み込む。音源を調べるとき (sourceDetect.ts) と、クロップで書き出すとき (cropRender.ts) に使う
import { load, type Kiln } from '../kiln/wasm/kiln';
// CSP の connect-src 'none' では fetch で wasm を読めない (data: URL も止まる) ので、チャンクに埋め込んでバイト列で渡す
import kilnWasm from '../kiln/zig-out/kiln.wasm?url&inline';

function toBytes(dataUrl: string): Uint8Array<ArrayBuffer> {
  const text = atob(dataUrl.slice(dataUrl.indexOf(',') + 1));
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

// 一度読み込んだら使い回す。失敗したときは残さず、次に使うときに読み直す
let kiln: Promise<Kiln> | null = null;
export function loadKiln(): Promise<Kiln> {
  if (!kiln) {
    const loading = load(toBytes(kilnWasm));
    loading.catch(() => { if (kiln === loading) kiln = null; });
    kiln = loading;
  }
  return kiln;
}
