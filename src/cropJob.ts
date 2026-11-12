// クロップの書き出しで kiln が行う処理。重い処理 (デコードやエンコード) があるので、Worker (cropWorker.ts) で動かす。
// どの音源から、どの形式を、kiln のどの関数で書くかは、下の 2 つの表にまとめる
import type { Kiln } from '../kiln/wasm/kiln';

// kiln で読める音源の種類
export type BytesKind = 'mp3' | 'flac' | 'ogg' | 'm4a' | 'wav';
// 書き出す形式。native は元の形式のまま切り出す (mp3、FLAC、Ogg、m4a)。WAV の音源の wav も、元の形式のまま切り出す
export type JobOutput = 'native' | 'wav' | 'flac';

export type CropJob =
  // kiln で読める音源。音源のバイト列の startSample 以上 endSample 未満 (音源のサンプル) を書く。float は浮動小数点の WAV か
  | { kind: BytesKind; output: JobOutput; bytes: Uint8Array<ArrayBuffer>; startSample: number; endSample: number; float: boolean }
  // kiln で読めない音源。ブラウザでデコードした PCM (区間だけ) を書く。start は区間の先頭 (秒)
  | { kind: 'pcm'; output: 'wav' | 'flac'; channels: Float32Array<ArrayBuffer>[]; sampleRate: number; start: number };

export interface CropResult {
  data: Uint8Array<ArrayBuffer>;
  start: number;           // 実際に切り始めた位置 (秒)
  invalidFrames: number;   // 壊れていて無音にしたフレームの数 (FLAC の切り出しと、mp3 / FLAC のデコード)
}

// WAV と FLAC を整数で書くときのビット深度。元のビット深度を保つもの (WAV と FLAC の音源) と、浮動小数点の WAV の FLAC は除く
const WAV_SAMPLE_FORMAT = 'i16';
const BITS = 16;
// 浮動小数点の WAV を FLAC にするときのビット深度。FLAC は整数しか持てないので、細かさをなるべく残す。±1.0 を超えるサンプルはクリップする
const FLOAT_WAV_FLAC_BITS = 24;

type BytesSource = Extract<CropJob, { kind: BytesKind }>;
type Written = { data: Uint8Array<ArrayBuffer>; start: number; invalidFrames?: number };
const range = (s: BytesSource) => ({ startSample: s.startSample, endSample: s.endSample });

// kiln で読める音源から書く。音源の種類に、ない形式は書けない (Ogg と m4a の WAV と FLAC は、ブラウザでデコードした PCM から書く)
const FROM_BYTES: Record<BytesKind, Partial<Record<JobOutput, (k: Kiln, s: BytesSource) => Written>>> = {
  mp3: {
    native: (k, s) => k.mp3.trim(s.bytes, range(s)),   // 再エンコードせずにサンプル単位で切り出す
    wav: (k, s) => k.mp3.toWav(s.bytes, { ...range(s), format: WAV_SAMPLE_FORMAT }),
    flac: (k, s) => k.mp3.toFlac(s.bytes, { ...range(s), bitsPerSample: BITS }),
  },
  flac: {
    native: (k, s) => k.flac.trim(s.bytes, range(s)),   // 可逆。区間の先頭と末尾にかかるフレームだけ作り直す
    wav: (k, s) => k.flac.toWav(s.bytes, range(s)),     // format を省くと、元のビット深度を保つ形式で書く (可逆)
  },
  // パケットをコピーして切り出す。Opus は区間の前の 80ms も残し、pre-skip とグラニュール位置で前後を捨てさせる。
  // Vorbis は先頭をパケットの区切りに寄せ、末尾はグラニュール位置で捨てさせる
  ogg: { native: (k, s) => k.ogg.trim(s.bytes, range(s)) },
  // フレームをコピーして切り出す。前の 2 フレームと後ろの 1 フレームも残し、編集リストと iTunSMPB で前後を捨てさせる。
  // タイムスケールは元のままで、HE-AAC は 2 サンプル単位
  m4a: { native: (k, s) => k.m4a.trim(s.bytes, range(s)) },
  wav: {
    wav: (k, s) => k.wav.trim(s.bytes, range(s)),   // 元の形式のままバイト列を切り出す
    // bitsPerSample を省くと、整数の WAV は元のビット深度のまま (可逆)
    flac: (k, s) => k.wav.toFlac(s.bytes, { ...range(s), ...(s.float ? { bitsPerSample: FLOAT_WAV_FLAC_BITS } : {}) }),
  },
};

// ブラウザでデコードした PCM から書く
const FROM_PCM: Record<'wav' | 'flac', (k: Kiln, channels: Float32Array[], sampleRate: number) => Uint8Array<ArrayBuffer>> = {
  wav: (k, channels, sampleRate) => k.wav.encode(channels, { sampleRate, format: WAV_SAMPLE_FORMAT }),
  flac: (k, channels, sampleRate) => k.flac.encode(channels, { sampleRate, bitsPerSample: BITS }),
};

export function runCropJob(k: Kiln, job: CropJob): CropResult {
  if (job.kind === 'pcm') return { data: FROM_PCM[job.output](k, job.channels, job.sampleRate), start: job.start, invalidFrames: 0 };
  const write = FROM_BYTES[job.kind][job.output];
  if (!write) throw new Error(`${job.kind} の音源から ${job.output} は書けません`);
  const r = write(k, job);
  return { data: r.data, start: r.start, invalidFrames: r.invalidFrames ?? 0 };
}
