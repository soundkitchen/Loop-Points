// 音源の一部を、指定の形式のファイルにする。main からはクロップモードに切り替えたときに読み込む。
// 音源を調べる (inspect) のはこのスレッドで、書き出す (renderCrop) のは Worker (cropWorker.ts) で行う。
// どの音源からどの形式を、kiln のどの関数で書くかは cropJob.ts の表にまとめている。
//   mp3、FLAC、Ogg (Opus、Vorbis)、m4a (AAC) → 元の形式: 再エンコードせずに切り出す
//   aac (ADTS) → m4a: 再エンコードせずに、m4a に入れ替えて切り出す
//   WAV → WAV: 元の形式のままバイト列を切り出す
//   mp3、FLAC、WAV → WAV か FLAC: kiln でデコードして (WAV は読んで) 書く
//   ほかの形式 → WAV か FLAC: ブラウザでデコードしたものを、kiln で書く (元のレートが分かればそのレート)
//   どの形式も → Ogg Vorbis: ブラウザでデコードしたものを、kiln (libvorbis) でエンコードする
import { KilnError, type AacInfo, type FlacInfo, type Kiln, type KilnErrorCode, type M4aInfo, type Mp3Info, type OggInfo, type WavInfo } from '../kiln/wasm/kiln';
import { OUT_FORMATS, extFormat, formatsFor, isOgg, type OutFormat } from './cropFormat';
import type { BytesKind, CropJob, CropResult, PcmOutput } from './cropJob';
import type { CropReply, CropRequest } from './cropWorker';
import { loadKiln } from './kilnLoader';
import { hasMp3Ext, sourceFormat } from './sourceDetect';

const NOT_READABLE = new Set<KilnErrorCode>(['NotMp3', 'NotWav', 'NotFlac', 'NotOgg', 'NotM4a', 'NotAac', 'UnsupportedFormat', 'InvalidWav', 'InvalidFlac', 'InvalidOgg', 'InvalidM4a']);

// kiln が扱えない入力 (MPEG-2 の mp3、壊れた FLAC など) なら null。それ以外のエラーはそのまま投げる
function probe<T>(read: () => T): T | null {
  try {
    return read();
  } catch (e) {
    if (e instanceof KilnError && NOT_READABLE.has(e.code)) return null;
    throw e;
  }
}

// kiln で読めた形式の情報。入るのは 1 つだけで、読めなければすべて null
interface Probed {
  wav: WavInfo | null;
  mp3: Mp3Info | null;
  flac: FlacInfo | null;
  ogg: OggInfo | null;   // Opus か Vorbis。切り出せないもの (trimmable が false) も入る
  m4a: M4aInfo | null;   // AAC か ALAC。切り出せないもの (trimmable が false) も入る
  aac: AacInfo | null;   // ADTS。切り出せないもの (trimmable が false) も入る
}

function probeSource(k: Kiln, fileName: string, bytes: Uint8Array<ArrayBuffer>): Probed {
  // 形式は kiln の detect で判定し (sourceDetect.ts。音源を開くときと同じ判定)、その形式の解析だけを呼ぶ。解析は、呼ぶたびに
  // 音源をまるごと wasm のメモリに写すので、合う形式を探して順に試さない
  const format = sourceFormat(k, fileName, bytes);
  const probed: Probed = {
    wav: format === 'wav' ? probe(() => k.wav.probe(bytes)) : null,
    mp3: format === 'mp3' ? probe(() => k.mp3.probe(bytes)) : null,
    // flac.probe はすべてのフレームを走査するので、大きなファイルでは少し時間がかかる
    flac: format === 'flac' ? probe(() => k.flac.probe(bytes)) : null,
    ogg: format === 'ogg' ? probe(() => k.ogg.probe(bytes)) : null,
    m4a: format === 'm4a' ? probe(() => k.m4a.probe(bytes)) : null,
    aac: format === 'aac' ? probe(() => k.aac.probe(bytes)) : null,
  };
  // 拡張子が .mp3 で、ここまでで読めなかったとき (形式を判定できなかったか、判定した形式の解析で読めなかった) は、mp3 の解析を
  // 試す。detect は mp3 の最初のフレームを先頭の近くでしか探さないが、解析は終わりまで探すので、先頭に大きなゴミがある mp3 も
  // 読める。RIFF で包んだ mp3 (detect は WAV と判定し、WAV の解析は中身が PCM でないので読めない) も、ここで読める
  if (format !== 'mp3' && hasMp3Ext(fileName) && Object.values(probed).every((info) => info === null)) probed.mp3 = probe(() => k.mp3.probe(bytes));
  return probed;
}

// 書き出す前に調べた音源。書き出しは、元のファイルを読み直さずにこのバイト列を使う。
// 保存先に元の音源を選ぶと、保存先を選んだ時点で Chromium がそのファイルを空にして、読めなくなるため
export interface CropSource {
  file: File;
  formats: OutFormat[];   // 書き出せる形式。先頭が初期値。元の形式 (kiln で無劣化で切れる mp3、FLAC、Ogg、m4a のときだけ。aac は m4a)、WAV、FLAC、Ogg Vorbis (エンコード)
  mp3Start: number;       // mp3 で書き出すときに切り始められる最初の位置 (秒)。長さの情報のない mp3 は 529 サンプル
  bytes: Uint8Array<ArrayBuffer>;
  wav: WavInfo | null;
  mp3: Mp3Info | null;
  flac: FlacInfo | null;
  ogg: OggInfo | null;    // 元の形式のまま切り出せる Ogg (Opus、Vorbis) のときだけ
  m4a: M4aInfo | null;    // 元の形式のまま切り出せる m4a (AAC) のときだけ
  aac: AacSource | null;  // m4a に入れ替えて切り出せる aac (ADTS) のときだけ
  // ブラウザでデコードした長さと kiln が数えた長さが違う (壊れたフレームをブラウザが飛ばしたなど)。
  // 波形の位置と書き出す位置がずれるので、書き出さない
  lengthMismatch: boolean;
}

// m4a に入れ替えて切り出せる aac。sampleRate と samples はデコード結果のもの (HE-AAC はヘッダーの 2 倍)
interface AacSource { sampleRate: number; samples: number; sbr: boolean }

// decoded はブラウザでデコードした音源。converted は、元のレートが分からず、出力の機器のレートに変換してデコードしたものか
export async function inspect(file: File, decoded: AudioBuffer, converted: boolean): Promise<CropSource> {
  const k = await loadKiln();
  const bytes = new Uint8Array(await file.arrayBuffer());
  const { wav, mp3, flac, ogg: oggInfo, m4a: m4aInfo, aac: aacInfo } = probeSource(k, file.name, bytes);
  // decoded のレートのサンプル数で比べる。decoded はふつう元のレートのままで、長さはサンプル単位で合う。出力の機器のレートに
  // 変換してデコードした音源 (sourceDetect.ts) の丸めの分と、ブラウザと kiln の数え方の小さな違いは許す
  const sameLength = (samples: number, sampleRate: number) => Math.abs(decoded.length - (samples * decoded.sampleRate) / sampleRate) <= 2;
  const lengthMismatch = flac !== null && !sameLength(flac.samples, flac.sampleRate);
  // Ogg は、kiln が切り出せる (trimmable。読めないページがなく、先頭の切り詰めのある Vorbis でない) うえで、
  // ブラウザと長さが合うときだけ元の形式のまま切り出す。それ以外は WAV か FLAC だけにする (どちらもブラウザのデコードから
  // 書くので、波形の位置とずれない)
  const ogg = oggInfo?.trimmable && sameLength(oggInfo.samples, oggInfo.sampleRate) ? oggInfo : null;
  // m4a も同じ。kiln が切り出せるのは AAC で、ALAC (ブラウザで開けない) と HE-AAC v2 などは WAV か FLAC だけになる
  const m4a = m4aInfo?.trimmable && sameLength(m4aInfo.samples, m4aInfo.sampleRate) ? m4aInfo : null;
  // aac (ADTS) は m4a に入れ替えて切り出す。ヘッダーからは HE-AAC かどうかが分からないが、音源を開くときに WebCodecs で
  // 調べたレートのままデコードしてある (sourceDetect.ts) ので、decoded のレートとチャンネル数がデコード結果のもの。
  // レートがヘッダーの 1 倍 (AAC-LC) か 2 倍 (HE-AAC) で、kiln がそのレートで切り出せて、ブラウザと長さが合うときだけ。
  // チャンネル数は、ヘッダーと同じか、モノラルの HE-AAC で左右がまったく同じ (PS がない) こと。HE-AAC v2 (PS) は左右が
  // 違い、m4a と同じく切り出さない (途中から復号すると左右が元と違う)。それ以外は WAV か FLAC だけにする
  let aac: AacSource | null = null;
  if (aacInfo && !converted) {
    const scale = decoded.sampleRate / aacInfo.sampleRate;
    const sbr = scale === 2;
    const trimmable = sbr ? aacInfo.sbrTrimmable : scale === 1 && aacInfo.trimmable;
    const samples = aacInfo.samples * scale;
    const channels = decoded.numberOfChannels === aacInfo.channels || (sbr && aacInfo.channels === 1 && decoded.numberOfChannels === 2 && sameChannels(decoded));
    if (trimmable && channels && sameLength(samples, decoded.sampleRate)) aac = { sampleRate: decoded.sampleRate, samples, sbr };
  }
  const native: OutFormat | null = mp3 ? 'mp3' : flac ? 'flac' : ogg ? (ogg.codec === 'opus' && extFormat(file.name) === 'opus' ? 'opus' : 'ogg') : m4a || aac ? 'm4a' : null;
  const formats = formatsFor(native, { channels: decoded.numberOfChannels, sampleRate: decoded.sampleRate, vorbisNative: ogg?.codec === 'vorbis' });
  return { file, formats, mp3Start: mp3 ? mp3.minStart / mp3.sampleRate : 0, bytes, wav, mp3, flac, ogg, m4a, aac, lengthMismatch };
}

export interface Rendered {
  blob: Blob;
  start: number;           // 実際に切り始めた位置 (元の音源の秒)。無劣化の mp3 では指定より後ろに、Ogg Vorbis と HE-AAC の m4a・aac (2 サンプル単位) では前になることがある
  invalidFrames: number;   // 壊れていて無音にしたフレームの数 (FLAC の切り出しと、mp3 / FLAC のデコード)
  clipped: number;         // ±1.0 を超えていてクリップしたサンプルの数 (浮動小数点の WAV を FLAC にしたとき)
}

// ---- Worker ----

// 書き出しの Worker。最初に書き出すときに作り、使い回す。読み込めなかったときは捨てて、次に書き出すときに作り直す
let worker: Worker | null = null;
let nextId = 0;
const pending = new Map<number, { resolve: (r: CropResult) => void; reject: (e: Error) => void }>();

function cropWorker(): Worker {
  if (worker) return worker;
  const w = new Worker(new URL('./cropWorker.ts', import.meta.url), { type: 'module' });
  w.addEventListener('message', (e: MessageEvent<CropReply>) => {
    const p = pending.get(e.data.id);
    if (!p) return;
    pending.delete(e.data.id);
    if ('error' in e.data) p.reject(new Error(e.data.error));
    else p.resolve(e.data.result);
  });
  // Worker のスクリプトを読み込めなかったときなど。待っている書き出しはすべて失敗にする
  w.addEventListener('error', (e) => {
    e.preventDefault();
    if (worker === w) worker = null;
    w.terminate();
    for (const p of pending.values()) p.reject(new Error(`書き出しの処理を始められませんでした (${e.message || 'Worker error'})`));
    pending.clear();
  });
  worker = w;
  return w;
}

// transfer に入れたものは Worker に渡し、こちらでは使えなくなる
function runInWorker(job: CropJob, transfer: Transferable[] = []): Promise<CropResult> {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    cropWorker().postMessage({ id, job } satisfies CropRequest, transfer);
  });
}

// ---- 書き出し ----

// start 以上 end 未満 (decoded のサンプル) を書き出す。decoded は元のレートのまま (sourceDetect.ts) なので、kiln で切る位置と同じ
export async function renderCrop(source: CropSource, decoded: AudioBuffer, start: number, end: number, format: OutFormat): Promise<Rendered> {
  const { bytes, wav, mp3, flac, ogg, m4a, aac } = source;
  // rate のサンプルに直す。ふつうは decoded と同じレートで、位置は変わらない。違うのは、レートが範囲の外で、出力の機器の
  // レートに変換してデコードした音源だけ。そのときは、別々に丸めると短い範囲が 0 になるので、最低 1 サンプルは残す。
  // 後端が波形の末尾なら、音源の末尾まで (変換すると、波形の長さが丸めで 1 サンプルほど短くなり、換算すると末尾に届かない)
  const range = (rate: number, length: number) => {
    const startSample = Math.min(Math.round((start / decoded.sampleRate) * rate), length - 1);
    const endSample = end >= decoded.length ? length : Math.round((end / decoded.sampleRate) * rate);
    return { startSample, endSample: Math.min(Math.max(endSample, startSample + 1), length) };
  };
  // Worker には音源のバイト列の写しを渡す (元のバイト列は、次の書き出しのために残す)
  const fromBytes = (kind: BytesKind, output: 'native' | 'wav' | 'flac', info: { sampleRate: number; samples: number }): CropJob =>
    ({ kind, output, bytes, ...range(info.sampleRate, info.samples), float: kind === 'wav' && (wav!.format === 'f32' || wav!.format === 'f64'), sbr: kind === 'aac' && aac!.sbr });
  const notNative = (label: string) => new Error(`${source.file.name} は無劣化で切り出せる ${label} ではありません。WAV か FLAC で書き出してください`);
  // ブラウザでデコードしたものから書く。元のレートが分かった音源は元のレートで、分からなかった音源は出力の機器の
  // レートでデコードしてある。区間を写して Worker に渡す。波形と同じデータなので、位置は波形で選んだとおりになる
  const fromPcm = async (output: PcmOutput): Promise<Rendered> => {
    const { startSample, endSample } = range(decoded.sampleRate, decoded.length);
    const channels = Array.from({ length: decoded.numberOfChannels }, (_, c) => decoded.getChannelData(c).slice(startSample, endSample));
    const r = await runInWorker({ kind: 'pcm', output, channels, sampleRate: decoded.sampleRate, start: startSample / decoded.sampleRate }, channels.map((c) => c.buffer));
    return { blob: new Blob([r.data], { type: OUT_FORMATS[format].mime }), start: r.start, invalidFrames: 0, clipped: 0 };
  };

  let job: CropJob;
  if (format === 'vorbis') {
    // Ogg Vorbis へのエンコードは、どの音源もブラウザでデコードしたものから行う
    return fromPcm('vorbis');
  } else if (format === 'mp3') {
    if (!mp3) throw notNative('mp3');
    job = fromBytes('mp3', 'native', mp3);
  } else if (isOgg(format)) {
    if (!ogg || (format === 'opus' && ogg.codec !== 'opus')) throw notNative(format === 'opus' ? 'Ogg Opus' : 'Ogg');
    job = fromBytes('ogg', 'native', ogg);
  } else if (format === 'm4a') {
    if (m4a) job = fromBytes('m4a', 'native', m4a);
    else if (aac) job = fromBytes('aac', 'native', aac);   // aac (ADTS) は m4a に入れ替えて切り出す
    else throw notNative('m4a');
  } else if (format === 'flac' && flac) {
    job = fromBytes('flac', 'native', flac);   // FLAC の音源は FLAC のまま切り出す
  } else if (wav) {
    job = fromBytes('wav', format, wav);
  } else if (mp3) {
    job = fromBytes('mp3', format, mp3);
  } else if (flac) {
    job = fromBytes('flac', format, flac);
  } else {
    // kiln で読めない形式は、ブラウザでデコードしたものから書く
    return fromPcm(format);
  }
  // 浮動小数点の WAV を FLAC (整数) にすると、±1.0 を超えるサンプルはクリップされるので、数えて知らせる。
  // ブラウザは浮動小数点の WAV をそのままの値でデコードするので、decoded で数えられる
  const clipped = job.kind === 'wav' && job.float && job.output === 'flac' ? countClipped(decoded, range(decoded.sampleRate, decoded.length)) : 0;
  const r = await runInWorker(job);
  return { blob: new Blob([r.data], { type: OUT_FORMATS[format].mime }), start: r.start, invalidFrames: r.invalidFrames, clipped };
}

// 2 チャンネルの左右がまったく同じか
function sameChannels(decoded: AudioBuffer): boolean {
  const l = decoded.getChannelData(0), r = decoded.getChannelData(1);
  for (let i = 0; i < l.length; i++) if (l[i] !== r[i]) return false;
  return true;
}

function countClipped(decoded: AudioBuffer, { startSample, endSample }: { startSample: number; endSample: number }): number {
  let n = 0;
  for (let c = 0; c < decoded.numberOfChannels; c++) {
    const d = decoded.getChannelData(c);
    for (let i = startSample; i < Math.min(endSample, d.length); i++) if (d[i] > 1 || d[i] < -1) n++;
  }
  return n;
}
