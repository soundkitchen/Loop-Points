// WAV の読み書き。元が WAV なら再エンコードせずにバイト列を切り出すので、ビット深度もサンプルレートも変わらない
export interface WavLayout {
  fmt: Uint8Array;      // fmt チャンクの中身。そのまま書き戻す
  sampleRate: number;
  blockAlign: number;
  dataOffset: number;
  dataBytes: number;
}

const FORMAT_PCM = 1, FORMAT_FLOAT = 3, FORMAT_EXTENSIBLE = 0xfffe;
const ascii = (s: string) => Uint8Array.from(s, (c) => c.charCodeAt(0));

// サンプルを 1 つずつ切り出せる PCM と float の WAV だけを読む。それ以外 (ADPCM など) は null を返し、呼ぶ側で再エンコードする
// bytes はファイルの先頭だけでもよい。そのときは fileSize にファイル全体の大きさを渡す
export function parseWav(bytes: ArrayBuffer, fileSize = bytes.byteLength): WavLayout | null {
  const d = new DataView(bytes);
  const tag = (o: number) => String.fromCharCode(d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2), d.getUint8(o + 3));
  if (bytes.byteLength < 12 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') return null;
  let fmt: Uint8Array | null = null;
  for (let o = 12; o + 8 <= bytes.byteLength;) {
    const id = tag(o), size = d.getUint32(o + 4, true), body = o + 8;
    if (id === 'fmt ' && size >= 16 && body + size <= bytes.byteLength) {
      fmt = new Uint8Array(bytes, body, size);
    } else if (id === 'data') {
      if (!fmt) return null;
      const f = new DataView(fmt.buffer, fmt.byteOffset, fmt.byteLength);
      const format = f.getUint16(0, true) === FORMAT_EXTENSIBLE && fmt.length >= 26 ? f.getUint16(24, true) : f.getUint16(0, true);
      const blockAlign = f.getUint16(12, true);
      if ((format !== FORMAT_PCM && format !== FORMAT_FLOAT) || blockAlign === 0) return null;
      // ヘッダの長さが実際より長いファイルもあるので、ファイルの範囲に収める
      return { fmt, sampleRate: f.getUint32(4, true), blockAlign, dataOffset: body, dataBytes: Math.min(size, fileSize - body) };
    }
    o = body + size + (size & 1);   // チャンクは 2 バイト境界に揃っている
  }
  return null;
}

function wavHeader(fmt: Uint8Array, dataBytes: number): Uint8Array {
  const fmtPad = fmt.length & 1, dataPad = dataBytes & 1;
  const riffSize = 4 + 8 + fmt.length + fmtPad + 8 + dataBytes + dataPad;
  if (riffSize > 0xffffffff) throw new Error('WAV の上限 (4GB) を超えます');
  const head = new Uint8Array(12 + 8 + fmt.length + fmtPad + 8);
  const d = new DataView(head.buffer);
  head.set(ascii('RIFF'), 0);
  d.setUint32(4, riffSize, true);
  head.set(ascii('WAVEfmt '), 8);
  d.setUint32(16, fmt.length, true);
  head.set(fmt, 20);
  const data = 20 + fmt.length + fmtPad;
  head.set(ascii('data'), data);
  d.setUint32(data + 4, dataBytes, true);
  return head;
}

// フレーム startFrame 以上 endFrame 未満を切り出す。音声以外のチャンクは引き継がない (ループの情報などが切り出した音源と合わなくなるため)
export function sliceWav(source: Blob, w: WavLayout, startFrame: number, endFrame: number): Blob {
  const a = w.dataOffset + startFrame * w.blockAlign;
  const n = Math.min(endFrame - startFrame, Math.floor((w.dataOffset + w.dataBytes - a) / w.blockAlign)) * w.blockAlign;
  const parts: BlobPart[] = [wavHeader(w.fmt.slice(), n) as Uint8Array<ArrayBuffer>, source.slice(a, a + n)];
  if (n & 1) parts.push(new Uint8Array(1));
  return new Blob(parts, { type: 'audio/wav' });
}

// 16-bit PCM で書く。-32768〜32767 に丸めるので、16-bit の音源をデコードした値は同じ値に戻る
export function encodeWav16(channels: Float32Array[], sampleRate: number): Blob {
  const c = channels.length, frames = channels[0].length;
  const fmt = new Uint8Array(16);
  const f = new DataView(fmt.buffer);
  f.setUint16(0, FORMAT_PCM, true);
  f.setUint16(2, c, true);
  f.setUint32(4, sampleRate, true);
  f.setUint32(8, sampleRate * c * 2, true);
  f.setUint16(12, c * 2, true);
  f.setUint16(14, 16, true);
  const pcm = new Int16Array(frames * c);
  for (let ch = 0; ch < c; ch++) {
    const d = channels[ch];
    for (let i = 0; i < frames; i++) pcm[i * c + ch] = Math.max(-32768, Math.min(32767, Math.round(d[i] * 32768)));
  }
  return new Blob([wavHeader(fmt, pcm.byteLength) as Uint8Array<ArrayBuffer>, pcm], { type: 'audio/wav' });
}
