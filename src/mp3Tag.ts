// mp3 の先頭に Info / Xing フレームを足す。エンコーダの遅延と詰め物の長さを書いておくと、Chrome、Firefox、Safari は
// デコード時にそれを取り除き、位置も長さも元の音源と揃う。書かないと、ブラウザによって 529 サンプルの差が出る
const BITRATES = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];   // MPEG1 Layer III (kbps)
const SAMPLE_RATES = [44100, 48000, 32000];                                            // MPEG1
const FRAME_SAMPLES = 1152;
const ENCODER_DELAY = 576;   // LAME が先頭に足すサンプル数
const SIDE_INFO = { mono: 17, stereo: 32 };
const XING_BYTES = 120;      // 識別子、フラグ、フレーム数、バイト数、TOC、品質
const LAME_BYTES = 36;       // LAME 拡張部

const frameBytes = (bitrateIndex: number, rateIndex: number) => Math.floor((144000 * BITRATES[bitrateIndex]) / SAMPLE_RATES[rateIndex]);

function crc16(d: Uint8Array, n: number): number {
  let c = 0;
  for (let i = 0; i < n; i++) {
    c ^= d[i];
    for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xa001 : c >>> 1;
  }
  return c;
}

// フレーム数を数える。ビットレートが 1 種類なら固定ビットレートとして扱う
function scanFrames(mp3: Uint8Array) {
  let offset = 0, frames = 0;
  const bitrates = new Set<number>();
  while (offset < mp3.length) {
    const bitrate = mp3[offset + 2] >> 4;
    // 長さが決まらないフレーム (free format、不正なビットレートやレート) があると先に進めない
    if (mp3[offset] !== 0xff || (mp3[offset + 1] & 0xfe) !== 0xfa || bitrate === 0 || bitrate === 15 || ((mp3[offset + 2] >> 2) & 3) === 3) {
      throw new Error(`mp3 のフレームが不正です (${offset} バイト目)`);
    }
    bitrates.add(bitrate);
    offset += frameBytes(bitrate, (mp3[offset + 2] >> 2) & 3) + ((mp3[offset + 2] >> 1) & 1);
    frames++;
  }
  return { frames, constant: bitrates.size === 1 };
}

// samples は元の PCM のサンプル数。mp3 はエンコーダの出力そのもの (MPEG1 Layer III のフレームだけ) を渡す
export function addInfoTag(mp3: Uint8Array, samples: number): Uint8Array {
  if (mp3.length === 0) throw new Error('mp3 のフレームがありません');
  const { frames, constant } = scanFrames(mp3);
  const padding = frames * FRAME_SAMPLES - samples - ENCODER_DELAY;
  if (padding < 0 || padding > 0xfff) throw new Error(`mp3 の詰め物の長さが不正です (${padding})`);
  const rateIndex = (mp3[2] >> 2) & 3;
  const channelBits = mp3[3];
  const sideInfo = channelBits >> 6 === 3 ? SIDE_INFO.mono : SIDE_INFO.stereo;
  // タグが収まるビットレートのフレームにする
  let bitrate = mp3[2] >> 4;
  while (frameBytes(bitrate, rateIndex) < 4 + sideInfo + XING_BYTES + LAME_BYTES) {
    if (++bitrate >= BITRATES.length) throw new Error('mp3 のタグが収まりません');
  }
  const size = frameBytes(bitrate, rateIndex);

  const frame = new Uint8Array(size);
  const d = new DataView(frame.buffer);
  frame[0] = mp3[0];
  frame[1] = mp3[1] | 1;   // CRC なし
  frame[2] = (bitrate << 4) | (rateIndex << 2);
  frame[3] = channelBits;
  let p = 4 + sideInfo;
  for (const c of constant ? 'Info' : 'Xing') frame[p++] = c.charCodeAt(0);
  d.setUint32(p, 0x0f); p += 4;   // フレーム数、バイト数、TOC、品質の項目がある
  d.setUint32(p, frames); p += 4;
  d.setUint32(p, mp3.length + size); p += 4;
  for (let i = 0; i < 100; i++) frame[p + i] = Math.floor((i * 256) / 100);   // シーク用の表。正確な値は持たないので直線にする
  p += 100 + 4;
  const lame = p;
  // エンコーダ名は ffmpeg が書く形にする。LAME の名前だと、Safari がまれに長さを 1 フレーム前後長く読む (Safari 26.6 で確認)
  for (const c of 'Lavc63.1.') frame[p++] = c.charCodeAt(0);
  frame[lame + 21] = ENCODER_DELAY >> 4;
  frame[lame + 22] = ((ENCODER_DELAY & 0xf) << 4) | (padding >> 8);
  frame[lame + 23] = padding & 0xff;
  d.setUint32(lame + 28, mp3.length + size);
  d.setUint16(lame + 32, crc16(mp3, mp3.length));
  d.setUint16(lame + 34, crc16(frame, lame + 34));

  const out = new Uint8Array(size + mp3.length);
  out.set(frame);
  out.set(mp3, size);
  return out;
}
