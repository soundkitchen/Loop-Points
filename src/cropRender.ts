// 音源の一部を、指定の形式のファイルにする。kiln (kiln/) を使い、main からはクロップモードに切り替えたときに読み込む
//   mp3 → mp3: 再エンコードせずにサンプル単位で切り出す
//   mp3 → WAV: kiln でデコードして 16-bit で書く (元のサンプルレートのまま)
//   FLAC → FLAC: FLAC のまま切り出す (可逆。区間の先頭と末尾にかかるフレームだけ作り直す)
//   FLAC → WAV: kiln でデコードし、元のサンプルレートとビット深度のまま書く (可逆)
//   Ogg Opus → Ogg Opus: パケットをコピーして切り出す (区間の前の 80ms も残し、pre-skip とグラニュール位置で前後を捨てさせる)
//   Ogg Vorbis → Ogg Vorbis: パケットをコピーして切り出す (先頭はパケットの区切りに寄せ、末尾はグラニュール位置で捨てさせる)
//   WAV → WAV: 元の形式のままバイト列を切り出す
//   ほかの形式 → WAV: ブラウザでデコードし、kiln で 16-bit で書く (元のレートが分かればそのレート)
import { KilnError, load, type FlacInfo, type Kiln, type KilnErrorCode, type Mp3Info, type OggInfo, type WavInfo } from '../kiln/wasm/kiln';
// CSP の connect-src 'none' では fetch で wasm を読めない (data: URL も止まる) ので、チャンクに埋め込んでバイト列で渡す
import kilnWasm from '../kiln/zig-out/kiln.wasm?url&inline';
import { OUT_FORMATS, extFormat, formatsFor, isOgg, type OutFormat } from './cropFormat';
import { sampleRateOf, startsWith } from './sampleRate';

const WAV_SAMPLE_FORMAT = 'i16';

function toBytes(dataUrl: string): Uint8Array<ArrayBuffer> {
  const text = atob(dataUrl.slice(dataUrl.indexOf(',') + 1));
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

// 一度読み込んだら使い回す。失敗したときは残さず、次に調べるときに読み直す
let kiln: Promise<Kiln> | null = null;
function loadKiln(): Promise<Kiln> {
  if (!kiln) {
    const loading = load(toBytes(kilnWasm));
    loading.catch(() => { if (kiln === loading) kiln = null; });
    kiln = loading;
  }
  return kiln;
}

const NOT_READABLE = new Set<KilnErrorCode>(['NotMp3', 'NotWav', 'NotFlac', 'NotOgg', 'UnsupportedFormat', 'InvalidWav', 'InvalidFlac', 'InvalidOgg']);

// kiln が扱えない入力 (MPEG-2 の mp3、壊れた FLAC など) なら null。それ以外のエラーはそのまま投げる
function probe<T>(read: () => T): T | null {
  try {
    return read();
  } catch (e) {
    if (e instanceof KilnError && NOT_READABLE.has(e.code)) return null;
    throw e;
  }
}

// 書き出す前に調べた音源。書き出しは、元のファイルを読み直さずにこのバイト列を使う。
// 保存先に元の音源を選ぶと、保存先を選んだ時点で Chromium がそのファイルを空にして、読めなくなるため
export interface CropSource {
  file: File;
  formats: OutFormat[];   // 書き出せる形式。先頭が初期値。kiln で無劣化で切れる mp3、FLAC、Ogg だけ、元の形式を選べる
  mp3Start: number;       // mp3 で書き出すときに切り始められる最初の位置 (秒)。長さの情報のない mp3 は 529 サンプル
  bytes: Uint8Array<ArrayBuffer>;
  wav: WavInfo | null;
  mp3: Mp3Info | null;
  flac: FlacInfo | null;
  ogg: OggInfo | null;    // 元の形式のまま切り出せる Ogg (Opus、Vorbis) のときだけ
  // ブラウザでデコードした長さと kiln が数えた長さが違う (壊れたフレームをブラウザが飛ばしたなど)。
  // 波形の位置と書き出す位置がずれるので、書き出さない
  lengthMismatch: boolean;
}

export async function inspect(file: File, decoded: AudioBuffer): Promise<CropSource> {
  const k = await loadKiln();
  const bytes = new Uint8Array(await file.arrayBuffer());
  // 中身で判定する。mp3 はフレームの同期を探すので、ほかの形式を読み違えないよう拡張子が .mp3 のものに限る
  const wav = startsWith(bytes, 0, 'RIFF') ? probe(() => k.wav.probe(bytes)) : null;
  const mp3 = !wav && extFormat(file.name) === 'mp3' ? probe(() => k.mp3.probe(bytes)) : null;
  // FLAC は拡張子によらず調べる。flac.probe は ID3v2 タグを飛ばし、FLAC でなければフレームを読まずに NotFlac を返す。
  // FLAC ならすべてのフレームを走査するので、大きなファイルでは少し時間がかかる
  const flac = !wav && !mp3 ? probe(() => k.flac.probe(bytes)) : null;
  // ブラウザは decoded を AudioContext のレートに変換しているので、そのレートのサンプル数で比べる (変換の丸めの分は許す)
  const sameLength = (samples: number, sampleRate: number) => Math.abs(decoded.length - (samples * decoded.sampleRate) / sampleRate) <= 2;
  const lengthMismatch = flac !== null && !sameLength(flac.samples, flac.sampleRate);
  // Ogg は、kiln が切り出せる (trimmable。読めないページがなく、先頭の切り詰めのある Vorbis でない) うえで、
  // ブラウザと長さが合うときだけ元の形式のまま切り出す。それ以外は WAV だけにする (WAV はブラウザのデコードから
  // 書くので、波形の位置とずれない)
  const oggInfo = !wav && !mp3 && !flac ? probe(() => k.ogg.probe(bytes)) : null;
  const ogg = oggInfo?.trimmable && sameLength(oggInfo.samples, oggInfo.sampleRate) ? oggInfo : null;
  const native: OutFormat | null = mp3 ? 'mp3' : flac ? 'flac' : ogg ? (ogg.codec === 'opus' && extFormat(file.name) === 'opus' ? 'opus' : 'ogg') : null;
  return { file, formats: formatsFor(native), mp3Start: mp3 ? mp3.minStart / mp3.sampleRate : 0, bytes, wav, mp3, flac, ogg, lengthMismatch };
}

export interface Rendered {
  blob: Blob;
  start: number;           // 実際に切り始めた位置 (元の音源の秒)。無劣化の mp3 では指定より後ろに、Ogg Vorbis では前になることがある
  invalidFrames: number;   // 壊れていて無音にしたフレームの数 (FLAC の切り出しと、mp3 / FLAC のデコード)
}

// start 以上 end 未満 (decoded のサンプル) を書き出す。decoded は AudioContext のレートに変換されているので、
// 元のレートで切り、音を変換しないで済むようにする
export async function renderCrop(source: CropSource, decoded: AudioBuffer, start: number, end: number, format: OutFormat): Promise<Rendered> {
  const k = await loadKiln();
  const { bytes, wav, mp3, flac, ogg } = source;
  // rate のサンプルに直す。別々に丸めると短い範囲が 0 になるので、最低 1 サンプルは残す
  // 後端が波形の末尾なら、音源の末尾まで。ブラウザがレートを変換すると、波形の長さが丸めで 1 サンプルほど短くなり、
  // 換算すると末尾に届かないため
  const range = (rate: number, length: number) => {
    const startSample = Math.min(Math.round((start / decoded.sampleRate) * rate), length - 1);
    const endSample = end >= decoded.length ? length : Math.round((end / decoded.sampleRate) * rate);
    return { startSample, endSample: Math.min(Math.max(endSample, startSample + 1), length) };
  };
  const blob = (data: Uint8Array<ArrayBuffer>) => new Blob([data], { type: OUT_FORMATS[format].mime });

  if (format === 'mp3') {
    if (!mp3) throw new Error(`${source.file.name} は無劣化で切り出せる mp3 ではありません。WAV で書き出してください`);
    const r = k.mp3.trim(bytes, range(mp3.sampleRate, mp3.samples));
    return { blob: blob(r.data), start: r.start, invalidFrames: 0 };
  }
  if (format === 'flac') {
    if (!flac) throw new Error(`${source.file.name} は無劣化で切り出せる FLAC ではありません。WAV で書き出してください`);
    const r = k.flac.trim(bytes, range(flac.sampleRate, flac.samples));
    return { blob: blob(r.data), start: r.start, invalidFrames: r.invalidFrames };
  }
  if (isOgg(format)) {
    if (!ogg || (format === 'opus' && ogg.codec !== 'opus')) throw new Error(`${source.file.name} は無劣化で切り出せる ${format === 'opus' ? 'Ogg Opus' : 'Ogg'} ではありません。WAV で書き出してください`);
    const r = k.ogg.trim(bytes, range(ogg.sampleRate, ogg.samples));
    return { blob: blob(r.data), start: r.start, invalidFrames: 0 };
  }
  if (wav) {
    const r = k.wav.trim(bytes, range(wav.sampleRate, wav.samples));
    return { blob: blob(r.data), start: r.start, invalidFrames: 0 };
  }
  if (mp3) {
    const r = k.mp3.toWav(bytes, { ...range(mp3.sampleRate, mp3.samples), format: WAV_SAMPLE_FORMAT });
    return { blob: blob(r.data), start: r.start, invalidFrames: r.invalidFrames };
  }
  if (flac) {
    // format を省くと、元のビット深度を保つ形式で書く (16-bit にそろえない)
    const r = k.flac.toWav(bytes, range(flac.sampleRate, flac.samples));
    return { blob: blob(r.data), start: r.start, invalidFrames: r.invalidFrames };
  }
  // decodeAudioData は渡したバッファを使えなくする。bytes は次の書き出しでも使うので、写しを渡す
  const rate = sampleRateOf(bytes) ?? decoded.sampleRate;
  const audio = rate === decoded.sampleRate ? decoded : await new OfflineAudioContext(decoded.numberOfChannels, 1, rate).decodeAudioData(bytes.slice().buffer);
  const { startSample, endSample } = range(rate, audio.length);
  const channels = Array.from({ length: audio.numberOfChannels }, (_, c) => audio.getChannelData(c).subarray(startSample, endSample));
  return { blob: blob(k.wav.encode(channels, { sampleRate: rate, format: WAV_SAMPLE_FORMAT })), start: startSample / rate, invalidFrames: 0 };
}
