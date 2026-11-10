// kiln で調べない音源の元のサンプルレートを、ファイルの先頭から読む。Ogg と、kiln で読めなかった FLAC (壊れたものなど) に使う。
// 分からない形式 (m4a、aac など) は null を返し、呼ぶ側でデコード後のレートを使う。mp3、WAV、FLAC は、読めれば kiln が扱う

// OfflineAudioContext が受け付けるレートの範囲。外れた値はヘッダーが壊れているとみなし、デコード後のレートを使う
const MIN_RATE = 3000;
const MAX_RATE = 768000;

export const startsWith = (d: Uint8Array, at: number, s: string) => [...s].every((c, i) => d[at + i] === c.charCodeAt(0));

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
  if (startsWith(d, 0, 'fLaC') && d.length >= 21) return (d[18] << 12) | (d[19] << 4) | (d[20] >> 4);   // STREAMINFO の 20 ビット
  return null;
}

export function sampleRateOf(d: Uint8Array): number | null {
  const rate = headerRate(d);
  return rate !== null && rate >= MIN_RATE && rate <= MAX_RATE ? rate : null;
}
