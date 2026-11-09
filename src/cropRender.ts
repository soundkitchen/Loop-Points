// 音源の一部を、指定の形式のファイルにする。kiln (vendor/kiln) を使い、main からは書き出すときに読み込む
//   mp3 → mp3: 再エンコードせずにサンプル単位で切り出す
//   mp3 → WAV: kiln でデコードして 16-bit で書く (元のサンプルレートのまま)
//   WAV → WAV: 元の形式のままバイト列を切り出す
//   ほかの形式 → WAV: ブラウザでデコードし、kiln で 16-bit で書く (元のレートが分かればそのレート)
import { KilnError, load, type Kiln } from '../vendor/kiln/kiln.js';
// CSP の connect-src 'none' では fetch で wasm を読めない (data: URL も止まる) ので、チャンクに埋め込んでバイト列で渡す
import kilnWasm from '../vendor/kiln/kiln.wasm?url&inline';
import { OUT_FORMATS, extFormat, type OutFormat } from './cropFormat';
import { sampleRateOf } from './sampleRate';

const WAV_SAMPLE_FORMAT = 'i16';

function toBytes(dataUrl: string): Uint8Array<ArrayBuffer> {
  const text = atob(dataUrl.slice(dataUrl.indexOf(',') + 1));
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

// 一度読み込んだら使い回す。失敗したときは残さず、次の書き出しで読み直す
let kiln: Promise<Kiln> | null = null;
function loadKiln(): Promise<Kiln> {
  if (!kiln) {
    const loading = load(toBytes(kilnWasm));
    loading.catch(() => { if (kiln === loading) kiln = null; });
    kiln = loading;
  }
  return kiln;
}

// kiln が扱えない入力なら null。それ以外のエラーはそのまま投げる
function probe<T>(read: () => T): T | null {
  try {
    return read();
  } catch (e) {
    if (e instanceof KilnError && (e.code === 'NotMp3' || e.code === 'NotWav' || e.code === 'UnsupportedFormat' || e.code === 'InvalidWav')) return null;
    throw e;
  }
}

const startsWith = (d: Uint8Array, s: string) => [...s].every((c, i) => d[i] === c.charCodeAt(0));

export interface Rendered {
  blob: Blob;
  start: number;   // 実際に切り始めた位置 (元の音源の秒)。無劣化の mp3 では、指定より後ろになることがある
}

// start 以上 end 未満 (decoded のサンプル) を書き出す。decoded は AudioContext のレートに変換されているので、
// 元のレートで切り、音を変換しないで済むようにする
export async function renderCrop(source: File, decoded: AudioBuffer, start: number, end: number, format: OutFormat): Promise<Rendered> {
  const k = await loadKiln();
  const bytes = new Uint8Array(await source.arrayBuffer());
  // rate のサンプルに直す。別々に丸めると短い範囲が 0 になるので、最低 1 サンプルは残す
  const range = (rate: number, length: number) => {
    const startSample = Math.min(Math.round((start / decoded.sampleRate) * rate), length - 1);
    return { startSample, endSample: Math.min(Math.max(Math.round((end / decoded.sampleRate) * rate), startSample + 1), length) };
  };
  const blob = (data: Uint8Array<ArrayBuffer>) => new Blob([data], { type: OUT_FORMATS[format].mime });

  // 中身で判定する。mp3 はフレームの同期を探すので、ほかの形式を読み違えないよう拡張子が .mp3 のものに限る
  const wav = startsWith(bytes, 'RIFF') ? probe(() => k.wav.probe(bytes)) : null;
  const mp3 = !wav && extFormat(source.name) === 'mp3' ? probe(() => k.mp3.probe(bytes)) : null;

  if (format === 'mp3') {
    if (!mp3) throw new Error(`${source.name} は無劣化で切り出せる mp3 ではありません。WAV で書き出してください`);
    const r = k.mp3.trim(bytes, range(mp3.sampleRate, mp3.samples));
    return { blob: blob(r.data), start: r.start };
  }
  if (wav) {
    const r = k.wav.trim(bytes, range(wav.sampleRate, wav.samples));
    return { blob: blob(r.data), start: r.start };
  }
  if (mp3) {
    const r = k.mp3.toWav(bytes, { ...range(mp3.sampleRate, mp3.samples), format: WAV_SAMPLE_FORMAT });
    return { blob: blob(r.data), start: r.start };
  }
  // decodeAudioData は渡したバッファを使えなくするので、写しを渡す
  const rate = sampleRateOf(bytes) ?? decoded.sampleRate;
  const audio = rate === decoded.sampleRate ? decoded : await new OfflineAudioContext(decoded.numberOfChannels, 1, rate).decodeAudioData(bytes.slice().buffer);
  const { startSample, endSample } = range(rate, audio.length);
  const channels = Array.from({ length: audio.numberOfChannels }, (_, c) => audio.getChannelData(c).subarray(startSample, endSample));
  return { blob: blob(k.wav.encode(channels, { sampleRate: rate, format: WAV_SAMPLE_FORMAT })), start: startSample / rate };
}
