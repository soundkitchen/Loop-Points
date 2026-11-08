// mp3 と Ogg Vorbis のエンコード。wasm は必要になってから読む
// CSP の connect-src 'none' で data: URL の fetch も止まるので、ライブラリの既定の読み込みは使わず、バイト列を渡す
import { createEncoder } from 'wasm-media-encoders/esnext';

// 分けて渡し、合間に画面が動くようにする。1 回で止まる時間を 1 フレーム (約 16ms) より短くする (mp3 で約 9ms)
const CHUNK_FRAMES = 1152 * 32;
const MP3_BITRATE = 192;
const OGG_QUALITY = 6;            // MP3_BITRATE と同じくらいのサイズになる

type Mime = 'audio/mpeg' | 'audio/ogg';
type Encoder = Awaited<ReturnType<typeof createEncoder>>;

// import の指定子は、Vite が埋め込めるように文字列のまま書く
const WASM: Record<Mime, () => Promise<{ default: string }>> = {
  'audio/mpeg': () => import('wasm-media-encoders/wasm/mp3?url&inline'),
  'audio/ogg': () => import('wasm-media-encoders/wasm/ogg?url&inline'),
};

function toBytes(dataUrl: string): ArrayBuffer {
  const text = atob(dataUrl.slice(dataUrl.indexOf(',') + 1));
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes.buffer;
}

const encoders = new Map<Mime, Promise<Encoder>>();

// 一度作ったエンコーダは使い回す。読み込みに失敗したときは残さず、次の書き出しで読み直す
function encoderFor(mime: Mime): Promise<Encoder> {
  let encoder = encoders.get(mime);
  if (!encoder) {
    encoder = WASM[mime]().then((m) => createEncoder(mime, toBytes(m.default)));
    encoders.set(mime, encoder);
    encoder.catch(() => encoders.delete(mime));
  }
  return encoder;
}

async function encode(mime: Mime, channels: Float32Array[], configure: (encoder: Encoder) => void): Promise<Uint8Array> {
  const encoder = await encoderFor(mime);
  configure(encoder);
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

export function encodeMp3(channels: Float32Array[], sampleRate: number): Promise<Uint8Array> {
  // outputSampleRate を省くと、低いビットレートで LAME がレートを下げ、位置が合わなくなる
  return encode('audio/mpeg', channels, (e) => e.configure({
    sampleRate, outputSampleRate: sampleRate as 32000 | 44100 | 48000, channels: channels.length as 1 | 2, bitrate: MP3_BITRATE,
  }));
}

export function encodeOgg(channels: Float32Array[], sampleRate: number): Promise<Uint8Array> {
  return encode('audio/ogg', channels, (e) => e.configure({ sampleRate, channels: channels.length as 1 | 2, vbrQuality: OGG_QUALITY }));
}
