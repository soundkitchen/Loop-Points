// 音源ファイルの先頭からサンプルレートを読む。分からない形式 (m4a など) は null を返し、呼ぶ側でデコード後のレートを使う
import { parseWav } from './wav';

const MPEG_RATES = [44100, 48000, 32000];

const startsWith = (d: Uint8Array, at: number, s: string) => [...s].every((c, i) => d[at + i] === c.charCodeAt(0));

// 先頭 (ID3v2 があればその直後) のフレームだけを見る。ファイルの中を探すと、WAV や m4a の中身をフレームと見間違える
function mp3Rate(d: Uint8Array): number | null {
  // ID3v2 の長さは 7 ビットずつの 4 バイトで書かれている
  const i = startsWith(d, 0, 'ID3') ? 10 + ((d[6] << 21) | (d[7] << 14) | (d[8] << 7) | d[9]) : 0;
  if (d[i] !== 0xff || (d[i + 1] & 0xe0) !== 0xe0) return null;
  const version = (d[i + 1] >> 3) & 3, layer = (d[i + 1] >> 1) & 3, bitrate = d[i + 2] >> 4, rate = (d[i + 2] >> 2) & 3;
  if (version === 1 || layer === 0 || bitrate === 15 || rate === 3) return null;
  return MPEG_RATES[rate] / (version === 3 ? 1 : version === 2 ? 2 : 4);
}

function oggRate(d: Uint8Array): number | null {
  const packet = 27 + d[26];   // 最初のページのヘッダの直後
  if (startsWith(d, packet, 'OpusHead')) return 48000;   // Opus のデコード結果は常に 48kHz
  if (d[packet] === 1 && startsWith(d, packet + 1, 'vorbis')) {
    return new DataView(d.buffer, d.byteOffset, d.byteLength).getUint32(packet + 12, true);
  }
  return null;
}

export function sampleRateOf(bytes: ArrayBuffer): number | null {
  const d = new Uint8Array(bytes);
  if (startsWith(d, 0, 'RIFF')) return parseWav(bytes)?.sampleRate ?? null;
  if (startsWith(d, 0, 'OggS')) return oggRate(d);
  if (startsWith(d, 0, 'fLaC')) return (d[18] << 12) | (d[19] << 4) | (d[20] >> 4);   // STREAMINFO の 20 ビット
  return mp3Rate(d);
}
