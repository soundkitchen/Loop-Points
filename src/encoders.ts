// mp3 と Ogg Vorbis のエンコード。wasm は必要になってから読む
// CSP の connect-src 'none' で data: URL の fetch も止まるので、ライブラリの既定の読み込みは使わず、バイト列を渡す
import { createEncoder } from 'wasm-media-encoders/esnext';

const CHUNK_FRAMES = 1152 * 64;   // 分けて渡し、合間に画面が動くようにする
const MP3_BITRATE = 192;
const OGG_QUALITY = 6;            // MP3_BITRATE と同じくらいのサイズになる

function toBytes(dataUrl: string): ArrayBuffer {
  const base64 = dataUrl.slice(dataUrl.indexOf(',') + 1);
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0)).buffer;
}

type Encoder = Awaited<ReturnType<typeof createEncoder>>;

async function encodeAll(encoder: Encoder, channels: Float32Array[]): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  for (let i = 0; i < channels[0].length; i += CHUNK_FRAMES) {
    // 戻り値はエンコーダの持つメモリを指すので、次の呼び出しの前に写す
    parts.push(encoder.encode(channels.map((c) => c.subarray(i, i + CHUNK_FRAMES))).slice());
    await new Promise((resolve) => setTimeout(resolve));
  }
  parts.push(encoder.finalize().slice());
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

let mp3: Promise<Encoder> | null = null;
let ogg: Promise<Encoder> | null = null;

export async function encodeMp3(channels: Float32Array[], sampleRate: number): Promise<Uint8Array> {
  mp3 ??= import('wasm-media-encoders/wasm/mp3?url&inline').then((m) => createEncoder('audio/mpeg', toBytes(m.default)));
  const encoder = await mp3;
  // outputSampleRate を省くと、低いビットレートで LAME がレートを下げ、位置が合わなくなる
  encoder.configure({ sampleRate, outputSampleRate: sampleRate as 32000 | 44100 | 48000, channels: channels.length as 1 | 2, bitrate: MP3_BITRATE });
  return encodeAll(encoder, channels);
}

export async function encodeOgg(channels: Float32Array[], sampleRate: number): Promise<Uint8Array> {
  ogg ??= import('wasm-media-encoders/wasm/ogg?url&inline').then((m) => createEncoder('audio/ogg', toBytes(m.default)));
  const encoder = await ogg;
  encoder.configure({ sampleRate, channels: channels.length as 1 | 2, vbrQuality: OGG_QUALITY });
  return encodeAll(encoder, channels);
}
