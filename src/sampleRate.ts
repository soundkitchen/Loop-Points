// kiln で読めない音源 (Ogg と FLAC) の元のサンプルレートを、ファイルの先頭から読む。
// 分からない形式 (m4a、aac など) は null を返し、呼ぶ側でデコード後のレートを使う。mp3 と WAV は kiln が読む

const startsWith = (d: Uint8Array, at: number, s: string) => [...s].every((c, i) => d[at + i] === c.charCodeAt(0));

function oggRate(d: Uint8Array): number | null {
  const packet = 27 + d[26];   // 最初のページのヘッダの直後
  if (startsWith(d, packet, 'OpusHead')) return 48000;   // Opus のデコード結果は常に 48kHz
  if (d[packet] === 1 && startsWith(d, packet + 1, 'vorbis')) {
    return new DataView(d.buffer, d.byteOffset, d.byteLength).getUint32(packet + 12, true);
  }
  return null;
}

export function sampleRateOf(d: Uint8Array): number | null {
  if (startsWith(d, 0, 'OggS')) return oggRate(d);
  if (startsWith(d, 0, 'fLaC')) return (d[18] << 12) | (d[19] << 4) | (d[20] >> 4);   // STREAMINFO の 20 ビット
  return null;
}
