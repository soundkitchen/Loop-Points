// 音源の形式と元のサンプルレートを kiln で調べる。音源を開くとき (main.ts の decode) と、クロップの書き出しの準備
// (cropRender.ts の inspect) に使う
import { KilnError, type FlacInfo, type Kiln, type KilnErrorCode, type M4aInfo, type Mp3Info, type OggInfo, type WavInfo } from '../kiln/wasm/kiln';
import { extFormat } from './cropFormat';
import { loadKiln } from './kilnLoader';

// AudioContext と OfflineAudioContext が受け付けるレートの範囲。外れた値は、元のレートが分からないものとして扱う
const MIN_RATE = 3000;
const MAX_RATE = 768000;

const startsWith = (d: Uint8Array, at: number, s: string) => [...s].every((c, i) => d[at + i] === c.charCodeAt(0));

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

// kiln で読めなかった Ogg と FLAC のレートを、ファイルの先頭から読む。kiln が扱わなくても、ブラウザはデコードできることがある
// (連結や多重化の Ogg、ヘッダーの後ろが壊れた Ogg、壊れた FLAC など)
function oggRate(d: Uint8Array): number | null {
  const packet = 27 + d[26];   // 最初のページのヘッダの直後
  if (startsWith(d, packet, 'OpusHead')) return 48000;   // Opus のデコード結果は常に 48kHz
  if (d[packet] === 1 && startsWith(d, packet + 1, 'vorbis') && d.length >= packet + 16) {
    return new DataView(d.buffer, d.byteOffset, d.byteLength).getUint32(packet + 12, true);
  }
  return null;
}

function headerRate(d: Uint8Array): number | null {
  if (startsWith(d, 0, 'OggS')) return oggRate(d);
  // 最初のメタデータブロックが STREAMINFO (種類 0) のときだけ読む。ほかのブロックなら 18〜20 バイト目は関係のない値
  if (startsWith(d, 0, 'fLaC') && d.length >= 21 && (d[4] & 0x7f) === 0) return (d[18] << 12) | (d[19] << 4) | (d[20] >> 4);   // STREAMINFO の 20 ビット
  return null;
}

// 音源の元のサンプルレート (デコード結果のレート。Opus は常に 48kHz)。分からなければ null で、呼ぶ側で出力の機器のレートを使う。
// 分からないのは、kiln で読めない形式 (.aac の ADTS は、ヘッダーから HE-AAC かどうかが分からない。MPEG-2 の mp3 など) と、
// SBR があるか分からない m4a (レートが実際の半分のことがある)
export function rateOf(p: Probed, bytes: Uint8Array): number | null {
  const m4a = p.m4a && p.m4a.sbr !== null ? p.m4a.sampleRate : null;
  const rate = p.wav?.sampleRate ?? p.mp3?.sampleRate ?? p.flac?.sampleRate ?? p.ogg?.sampleRate ?? m4a ?? headerRate(bytes);
  return rate !== null && rate >= MIN_RATE && rate <= MAX_RATE ? rate : null;
}

export async function sourceRate(fileName: string, bytes: Uint8Array<ArrayBuffer>): Promise<number | null> {
  return rateOf(probeSource(await loadKiln(), fileName, bytes), bytes);
}
