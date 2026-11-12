// 音源の形式を kiln で調べる。クロップの書き出しの準備 (cropRender.ts の inspect) に使う
import { KilnError, type FlacInfo, type Kiln, type KilnErrorCode, type M4aInfo, type Mp3Info, type OggInfo, type WavInfo } from '../kiln/wasm/kiln';
import { extFormat } from './cropFormat';
import { startsWith } from './sampleRate';

const NOT_READABLE = new Set<KilnErrorCode>(['NotMp3', 'NotWav', 'NotFlac', 'NotOgg', 'NotM4a', 'UnsupportedFormat', 'InvalidWav', 'InvalidFlac', 'InvalidOgg', 'InvalidM4a']);

// kiln が扱えない入力 (MPEG-2 の mp3、壊れた FLAC など) なら null。それ以外のエラーはそのまま投げる
function probe<T>(read: () => T): T | null {
  try {
    return read();
  } catch (e) {
    if (e instanceof KilnError && NOT_READABLE.has(e.code)) return null;
    throw e;
  }
}

// kiln で読めた形式の情報。入るのは 1 つだけで、どれでも読めなければすべて null
export interface Probed {
  wav: WavInfo | null;
  mp3: Mp3Info | null;
  flac: FlacInfo | null;
  ogg: OggInfo | null;   // Opus か Vorbis。切り出せないもの (trimmable が false) も入る
  m4a: M4aInfo | null;   // AAC か ALAC。切り出せないもの (trimmable が false) も入る
}

export function probeSource(k: Kiln, fileName: string, bytes: Uint8Array<ArrayBuffer>): Probed {
  // 中身で判定する。mp3 はフレームの同期を探すので、ほかの形式を読み違えないよう拡張子が .mp3 のものに限る
  const wav = startsWith(bytes, 0, 'RIFF') ? probe(() => k.wav.probe(bytes)) : null;
  const mp3 = !wav && extFormat(fileName) === 'mp3' ? probe(() => k.mp3.probe(bytes)) : null;
  // FLAC は拡張子によらず調べる。flac.probe は ID3v2 タグを飛ばし、FLAC でなければフレームを読まずに NotFlac を返す。
  // FLAC ならすべてのフレームを走査するので、大きなファイルでは少し時間がかかる
  const flac = !wav && !mp3 ? probe(() => k.flac.probe(bytes)) : null;
  const ogg = !wav && !mp3 && !flac ? probe(() => k.ogg.probe(bytes)) : null;
  const m4a = !wav && !mp3 && !flac && !ogg ? probe(() => k.m4a.probe(bytes)) : null;
  return { wav, mp3, flac, ogg, m4a };
}
