import { OUT_FORMATS, croppedName, formatOf, type OutFormat } from './cropFormat';
import { canWrite, fileAccessSupported, isAbort, pickAudioToSave, pickJsonToOpen, pickJsonToSave, writeContent } from './jsonFile';
import { parseLoops, serializeLoops, type LoopMap, type LoopPoints } from './loops';
import { LoopPlayer } from './player';
import { mixdown, nearestZeroCross, nextZeroCross } from './samples';
import { setupTheme } from './theme';
import { WaveformView, formatTime, type Marker, type Mode } from './waveform';

// 音源ごとのループポイントを決めるビューア。音源はブラウザ内で読み、決めた値は JSON に書き出す
// クロップモードでは音源の前後を切り落として、音源のファイルに書き出す
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const SNAP_PX = 10;          // ドラッグ中、この距離 (CSS px) 以内のゼロクロスに吸着する
const ZERO_CROSS_LIMIT = 1;  // 「◀ 0」「0 ▶」で探す範囲 (秒)
const MARKER_ZOOM = 0.02;    // 「拡大」で表示する幅 (秒)
// duration の不一致とみなす差 (秒)。サンプルレートの違いによる丸めは無視し、mp3 の無音 (数十ミリ秒) の差は拾う
const DURATION_TOLERANCE = 0.001;
const AUDIO_EXT = /\.(mp3|wav|ogg|opus|m4a|aac|flac|webm)$/i;
const JSON_EXT = /\.json$/i;
// ダウンロード用の Blob URL を残す時間 (ミリ秒)。すぐに破棄すると、ブラウザが読む前に消えて失敗することがある
const BLOB_URL_LIFETIME = 60_000;

const ctx = new AudioContext();
const player = new LoopPlayer(ctx);
const files = new Map<string, File>();   // 読み込んだ音源。キーはファイル名で、JSON の項目と対応する
type Crop = { start: number; end: number };   // クロップの範囲 (サンプル)。音源ごとに持ち、ファイルを読み直すと全体に戻る
type Decoded = { source: File; buffer: AudioBuffer; mono: Float32Array; crop: Crop };
const decoded = new Map<string, Decoded>();
const decoding = new Map<File, Promise<Decoded>>();   // デコード中の音源。同じファイルを二重にデコードしない

// 開いている音源。位置はサンプル
let name = '';
let buffer: AudioBuffer | null = null;
let mono: Float32Array = new Float32Array(0);
let start = 0, end = 0, cursor = 0;
let crop: Crop = { start: 0, end: 0 };
let playhead: number | null = null;
let mode: Mode = 'loop';

let loops: LoopMap = {};
let saved: LoopMap = {};   // 読み込んだ、または最後に書き出した JSON の値
// 上書き保存の対象。lastModified は外からの変更に気づくために控える。File System Access API が使えないときは常に null
let jsonTarget: { handle: FileSystemFileHandle; lastModified: number } | null = null;
let writing = false;       // 保存ダイアログを開いている間と書き込み中。この間は保存も JSON の読み込みもしない

const sr = () => buffer?.sampleRate ?? 44100;
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
// 秒は小数 6 桁で持つ。1 サンプル (44.1kHz で約 23µs) より細かいので、サンプルに戻しても同じ位置になる
const round6 = (v: number) => Math.round(v * 1e6) / 1e6;
// 消した項目も変更に含める。クロップで同じ名前の音源を置き換えると、項目を消すことがある
const isDirty = () => Object.keys(saved).some((k) => !(k in loops)) || Object.entries(loops).some(([k, p]) =>
  p.loopStart !== saved[k]?.loopStart || p.loopEnd !== saved[k]?.loopEnd || p.duration !== saved[k]?.duration);
// ループを決めた音源で、クロップの範囲がループ区間にかかっているか。決めていない音源は全体が区間なので対象にしない
const cropCutsLoop = () => loops[name] !== undefined && (crop.start > start || crop.end < end);

const view = new WaveformView($<HTMLCanvasElement>('wave'), $<HTMLCanvasElement>('overview'), () => ({ mode, start, end, cropStart: crop.start, cropEnd: crop.end, cursor, playhead }));
setupTheme(() => view.refreshColors());

// ---- ループポイントとクロップの線 ----

function setMarker(m: Marker, s: number) {
  if (!buffer) return;
  if (m === 'cropStart' || m === 'cropEnd') {
    if (m === 'cropStart') crop.start = clamp(Math.round(s), 0, crop.end - 1);
    else crop.end = clamp(Math.round(s), crop.start + 1, buffer.length);
    player.stop();   // 鳴らしている範囲と線がずれないよう、止める
    updatePanel();
    return;
  }
  if (m === 'start') start = clamp(Math.round(s), 0, end - 1);
  else end = clamp(Math.round(s), start + 1, buffer.length);
  loops[name] = { ...loops[name], loopStart: round6(start / sr()), loopEnd: round6(end / sr()), duration: round6(buffer.duration) };
  player.setLoop(start / sr(), end / sr());
  updatePanel();
}

// 開いている音源に loops の値を反映する。値がなければ全体をループにする (触るまでは JSON に書かない)
function applyLoop() {
  if (!buffer) return;
  const p = loops[name];
  // 古い JSON の項目は、音源を開いた時点で duration を補う。開いただけで未書き出しにならないよう saved にも入れる
  if (p && p.duration === undefined) {
    p.duration = round6(buffer.duration);
    if (saved[name]) saved[name].duration = p.duration;
  }
  start = p ? clamp(Math.round(p.loopStart * sr()), 0, buffer.length - 1) : 0;
  end = p ? clamp(Math.round(p.loopEnd * sr()), start + 1, buffer.length) : buffer.length;
  player.setLoop(start / sr(), end / sr());
  updatePanel();
}

view.onMarkerDrag = (m, s, spp) => {
  if ($<HTMLInputElement>('snap').checked) {
    s = nearestZeroCross(mono, clamp(s, 0, mono.length), Math.max(1, Math.round(spp * SNAP_PX))) ?? s;
  }
  setMarker(m, s);
};
view.onCursor = (s) => { cursor = s; };

// 今のモードで動かす 2 本の線。数値入力と微調整のボタンはこの 2 本に対応する
const MODE_MARKERS = { loop: ['start', 'end'], crop: ['cropStart', 'cropEnd'] } as const satisfies Record<Mode, readonly [Marker, Marker]>;
const MARKER_LABELS: Record<Marker, { label: string; color: string }> = {
  start: { label: '開始', color: 'var(--start)' },
  end: { label: '終了', color: 'var(--end)' },
  cropStart: { label: '前端', color: 'var(--crop)' },
  cropEnd: { label: '後端', color: 'var(--crop)' },
};
const positionOf = (m: Marker) => ({ start, end, cropStart: crop.start, cropEnd: crop.end })[m];

const panels = MODE_MARKERS.loop.map((_, i) => {
  const marker = () => MODE_MARKERS[mode][i];
  const el = document.createElement('div');
  el.className = 'marker';
  el.innerHTML = `
    <h2><span data-f="title"></span> <button data-act="zoom" title="この点を拡大して表示">拡大</button></h2>
    <div class="row">
      <label>秒 <input type="number" step="0.001" min="0" data-f="sec" /></label>
      <label>サンプル <input type="number" step="1" min="0" data-f="samples" /></label>
    </div>
    <div class="row">
      <button data-zc="-1" title="前のゼロクロスへ">◀ 0</button>
      <button data-ms="-10">-10ms</button>
      <button data-ms="-1">-1ms</button>
      <button data-n="-1">-1</button>
      <button data-n="1">+1</button>
      <button data-ms="1">+1ms</button>
      <button data-ms="10">+10ms</button>
      <button data-zc="1" title="次のゼロクロスへ">0 ▶</button>
    </div>`;
  $('markers').append(el);
  const pos = () => positionOf(marker());
  const sec = el.querySelector<HTMLInputElement>('[data-f=sec]')!;
  const samples = el.querySelector<HTMLInputElement>('[data-f=samples]')!;
  // 空や数でない入力は、マーカーを動かさずに表示を戻す (Number('') は 0 になるので跳んでしまう)
  const input = (el: HTMLInputElement, toSample: (v: number) => number) => {
    const v = Number(el.value);
    if (el.value.trim() === '' || !Number.isFinite(v)) updatePanel();
    else setMarker(marker(), toSample(v));
  };
  sec.addEventListener('change', () => input(sec, (v) => v * sr()));
  samples.addEventListener('change', () => input(samples, (v) => v));
  el.querySelector('[data-act=zoom]')!.addEventListener('click', () => view.zoomTo(pos(), MARKER_ZOOM * sr()));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-n]')) b.addEventListener('click', () => setMarker(marker(), pos() + Number(b.dataset.n)));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-ms]')) b.addEventListener('click', () => setMarker(marker(), pos() + Math.round((Number(b.dataset.ms) / 1000) * sr())));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-zc]')) {
    b.addEventListener('click', () => {
      const z = nextZeroCross(mono, pos(), Number(b.dataset.zc) as 1 | -1, ZERO_CROSS_LIMIT * sr());
      if (z !== null) setMarker(marker(), z);
    });
  }
  return { el, sec, samples, title: el.querySelector<HTMLElement>('[data-f=title]')! };
});

function updatePanel() {
  MODE_MARKERS[mode].forEach((m, i) => {
    const s = positionOf(m);
    panels[i].sec.value = (s / sr()).toFixed(6);
    panels[i].samples.value = String(s);
  });
  const [a, z] = mode === 'crop' ? [crop.start, crop.end] : [start, end];
  $('length').textContent = `${formatTime((z - a) / sr())} (${z - a} サンプル)`;
  updateWarning();
  updateStatus();
}

// ---- モード ----

function setMode(next: Mode) {
  player.stop();
  mode = next;
  const inCrop = mode === 'crop';
  for (const b of document.querySelectorAll<HTMLButtonElement>('[data-mode]')) b.setAttribute('aria-pressed', String(b.dataset.mode === mode));
  MODE_MARKERS[mode].forEach((m, i) => {
    panels[i].title.textContent = MARKER_LABELS[m].label;
    panels[i].el.style.setProperty('--c', MARKER_LABELS[m].color);
  });
  $('length-label').textContent = inCrop ? 'クロップ後の長さ' : 'ループの長さ';
  $('crop-tools').hidden = !inCrop;
  const playFirst = $('play-intro'), playSeam = $('play-seam');
  playFirst.textContent = inCrop ? '▶ 前端から' : '▶ 頭から';
  playFirst.title = inCrop ? '前端から後端まで 1 回再生する' : 'イントロを 1 回流してからループ区間を繰り返す';
  playSeam.textContent = inCrop ? '▶ 後端の手前から' : '▶ つなぎ目の手前から';
  playSeam.title = inCrop ? '後端の少し前から再生して、終わり方をすぐ聴く' : 'ループの終わりの少し前から再生して、つなぎ目をすぐ聴く';
  updatePanel();
}

for (const b of document.querySelectorAll<HTMLButtonElement>('[data-mode]')) {
  b.addEventListener('click', () => setMode(b.dataset.mode as Mode));
}

// JSON の duration と開いている音源の長さが違えば知らせる。区間を動かすと今の音源の長さで記録し直すので消える
function updateWarning() {
  const want = loops[name]?.duration;
  const mismatch = buffer !== null && want !== undefined && Math.abs(want - buffer.duration) > DURATION_TOLERANCE;
  const messages = [];
  if (mismatch) messages.push(`${name}: JSON の duration (${formatTime(want)}) と音源の長さ (${formatTime(buffer!.duration)}) が違います。別の音源か、デコードの差でループ位置がずれている可能性があります`);
  if (mode === 'crop' && cropCutsLoop()) messages.push('クロップの範囲がループ区間にかかっているので、書き出せません。線を区間の外へ動かすか、ループモードで区間を動かしてください');
  $('warning').textContent = messages.join('\n');
}

// ---- JSON の読み込みと書き出し ----

function updateStatus() {
  const dirty = isDirty();
  // 読み込んだ項目をすべて消したときも、空の JSON を保存できるようにする
  const hasLoops = Object.keys(loops).length > 0 || Object.keys(saved).length > 0;
  $('status').textContent = dirty ? '未書き出しの変更があります' : hasLoops ? '変更なし' : '';
  $('status').classList.toggle('dirty', dirty);
  const save = $<HTMLButtonElement>('save');
  const download = $<HTMLButtonElement>('download');
  save.hidden = jsonTarget === null;
  save.textContent = jsonTarget ? `上書き保存 (${jsonTarget.handle.name})` : '';
  save.disabled = !hasLoops || writing;
  download.disabled = !hasLoops || writing;
  download.classList.toggle('primary', jsonTarget === null);
  $<HTMLButtonElement>('copy').disabled = !hasLoops;
  $<HTMLButtonElement>('export-crop').disabled = !buffer || writing || cropCutsLoop();
}

// handle を渡すと、そのファイルを上書き保存の対象にする。渡さなければ対象をなくす
// (前の対象を残すと、読み込んだものとは別のファイルを上書きしてしまう)
async function loadLoops(file: File, handle: FileSystemFileHandle | null = null) {
  let parsed: LoopMap;
  try {
    parsed = parseLoops(await file.text());
  } catch (e) {
    alert(`${file.name} を読めませんでした (${e})`);
    return;
  }
  if (writing) {
    alert(`保存中なので ${file.name} を読み込みませんでした`);
    return;
  }
  if (isDirty() && !confirm(`未書き出しの変更を破棄して ${file.name} を読み込みますか?`)) return;
  saved = parsed;
  loops = structuredClone(parsed);
  jsonTarget = handle && { handle, lastModified: file.lastModified };
  applyLoop();
  updateStatus();
}

// 書き出した内容を基準にする。書き出しの間に変えた分を書き出し済みと扱わないよう、呼ぶ側で控えた時点の中身を渡す
function markExported(sent: LoopMap) {
  saved = sent;
  updateStatus();
}

async function whileWriting(failure: string, task: () => Promise<void>) {
  writing = true;
  updateStatus();
  try {
    await task();
  } catch (e) {
    if (!isAbort(e)) alert(`${failure} (${e})`);
  } finally {
    writing = false;
    updateStatus();
  }
}

function downloadBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), BLOB_URL_LIFETIME);
}

const JSON_FAILURE = 'JSON を保存できませんでした';

$('save').addEventListener('click', () => void whileWriting(JSON_FAILURE, async () => {
  const target = jsonTarget!;
  const fileName = target.handle.name;
  if (!(await canWrite(target.handle))) {
    alert(`${fileName} への書き込みが許可されませんでした`);
    return;
  }
  const current = await target.handle.getFile();
  if (current.lastModified !== target.lastModified && !confirm(`${fileName} は読み込んだあとに変更されています。上書きしますか?`)) return;
  const sent = structuredClone(loops);
  target.lastModified = await writeContent(target.handle, serializeLoops(sent));
  markExported(sent);
}));

$('download').addEventListener('click', () => {
  if (fileAccessSupported) {
    void whileWriting(JSON_FAILURE, async () => {
      const handle = await pickJsonToSave(jsonTarget?.handle.name ?? 'loops.json');
      const sent = structuredClone(loops);
      const lastModified = await writeContent(handle, serializeLoops(sent));
      jsonTarget = { handle, lastModified };
      markExported(sent);
    });
    return;
  }
  downloadBlob(new Blob([serializeLoops(loops)], { type: 'application/json' }), 'loops.json');
  // ダウンロードの成否はページから分からないので、押した時点で書き出し済みとする
  markExported(structuredClone(loops));
});

// クリップボードはすぐ上書きされるので、コピーしても書き出し済みとはしない
$('copy').addEventListener('click', async () => {
  const button = $<HTMLButtonElement>('copy');
  try {
    await navigator.clipboard.writeText(serializeLoops(loops));
  } catch (e) {
    alert(`コピーできませんでした (${e})`);
    return;
  }
  button.textContent = 'コピーしました';
  setTimeout(() => { button.textContent = 'JSON をコピー'; }, 1500);
});

addEventListener('beforeunload', (e) => {
  if (isDirty()) e.preventDefault();
});

// ---- 音源の読み込み ----

let openToken = 0;   // 最後に呼んだ open を見分ける。読み込み中に別の音源へ切り替えたら、前の open は何もしない

function decode(file: string, source: File): Promise<Decoded> {
  let pending = decoding.get(source);
  if (!pending) {
    pending = (async () => {
      try {
        const b = await ctx.decodeAudioData(await source.arrayBuffer());
        const d = { source, buffer: b, mono: mixdown(b), crop: { start: 0, end: b.length } };
        // デコード中に同じ名前のファイルで置き換えられていたら、古い結果は残さない
        if (files.get(file) === source) decoded.set(file, d);
        return d;
      } catch (e) {
        // 開けなかったファイルは一覧に残さない。同じ名前の置き換えに失敗したときは、前のファイルに戻す
        if (files.get(file) === source) {
          const old = decoded.get(file);
          if (old) files.set(file, old.source);
          else files.delete(file);
          updateFileList();
        }
        throw e;
      } finally {
        decoding.delete(source);
      }
    })();
    decoding.set(source, pending);
  }
  return pending;
}

async function open(file: string): Promise<'opened' | 'failed' | 'superseded'> {
  player.stop();
  playhead = null;
  const token = ++openToken;
  // 読み込みが終わるまでは、前の音源のマーカーを動かしたり鳴らしたりできないようにする
  // (name は読み込めてから変える。先に変えると、前の音源の位置が新しい音源の項目に入る)
  buffer = null;
  $('info').textContent = '読み込み中…';
  const source = files.get(file)!;
  const cached = decoded.get(file);
  let d: Decoded;
  try {
    d = cached?.source === source ? cached : await decode(file, source);
  } catch (e) {
    if (token !== openToken) return 'superseded';
    // 開けなかったら前の音源に戻す
    const prev = decoded.get(name);
    if (prev) { buffer = prev.buffer; mono = prev.mono; crop = prev.crop; applyLoop(); }
    select.value = name;
    $('info').textContent = `${file} を開けませんでした (${e})` + (name ? `。${name} のままです` : '');
    return 'failed';
  }
  if (token !== openToken) return 'superseded';
  name = file;
  buffer = d.buffer;
  mono = d.mono;
  crop = d.crop;
  cursor = 0;
  outFormat.value = formatOf(file);
  $('info').textContent = `${buffer.sampleRate} Hz · ${buffer.numberOfChannels}ch · ${formatTime(buffer.duration)} (${buffer.length} サンプル)`;
  view.setData(mono, buffer.sampleRate);
  applyLoop();
  return 'opened';
}

// 一覧を作り直す。選択が消えないよう、呼ぶ側で必要なら選び直す
function updateFileList() {
  const current = select.value;
  select.replaceChildren(...[...files.keys()].sort().map((n) => new Option(n, n)));
  select.value = current;
  select.hidden = files.size === 0;
}

// ドロップで受け取ったハンドルから、名前の合うファイルのものを探す。取れないものは無視する
async function findFileHandle(handles: Promise<FileSystemHandle | null>[], fileName: string) {
  for (const r of await Promise.allSettled(handles)) {
    if (r.status === 'fulfilled' && r.value?.kind === 'file' && r.value.name === fileName) return r.value as FileSystemFileHandle;
  }
  return null;
}

// 音源と JSON をまとめて受け取る。JSON を先に読むので、一緒に渡した音源には JSON の値が反映される
async function addFiles(list: File[], handles: Promise<FileSystemHandle | null>[] = []) {
  const audio = list.filter((f) => AUDIO_EXT.test(f.name)).sort((a, b) => (a.name < b.name ? -1 : 1));
  const json = list.filter((f) => JSON_EXT.test(f.name));
  const ignored = list.filter((f) => !AUDIO_EXT.test(f.name) && !JSON_EXT.test(f.name));
  if (json.length > 1) alert('JSON は 1 つずつ読み込んでください。JSON は読み込みませんでした');
  else if (json.length === 1) await loadLoops(json[0], await findFileHandle(handles, json[0].name));
  if (audio.length > 0) {
    // 同じ名前の音源は新しいファイルで置き換える
    for (const f of audio) files.set(f.name, f);
    updateFileList();
    // 開ける音源が見つかるまで順に試す
    const failed: string[] = [];
    let result: Awaited<ReturnType<typeof open>> = 'failed';
    // 別のフォルダの同名ファイルは files で 1 つにまとまるので、名前ごとに 1 回だけ試す
    for (const fileName of new Set(audio.map((f) => f.name))) {
      select.value = fileName;
      result = await open(fileName);
      if (result !== 'failed') break;
      failed.push(fileName);
    }
    // 最後の失敗だけは open が画面に出しているので、それ以外にもあれば伝える
    if (result !== 'superseded' && failed.length > (result === 'opened' ? 0 : 1)) alert(`開けませんでした: ${failed.join(', ')}`);
  }
  if (ignored.length > 0) alert(`音源でも JSON でもないので読み込みませんでした: ${ignored.map((f) => f.name).join(', ')}`);
}

const select = $<HTMLSelectElement>('file');
select.addEventListener('change', () => void open(select.value));

// ボタンから、隠してあるファイル選択を開く
const audioInput = $<HTMLInputElement>('audio-input');
const jsonInput = $<HTMLInputElement>('json-input');
for (const input of [audioInput, jsonInput]) {
  input.addEventListener('change', () => {
    const picked = [...(input.files ?? [])];
    input.value = '';   // 同じファイルをもう一度選んでも change が起きるように空にする
    void addFiles(picked);
  });
}
$('open-audio').addEventListener('click', () => audioInput.click());
$('open-json').addEventListener('click', async () => {
  if (!fileAccessSupported) {
    jsonInput.click();
    return;
  }
  // 上書き保存できるよう、ハンドルが取れる方法で開く
  try {
    const handle = await pickJsonToOpen();
    await loadLoops(await handle.getFile(), handle);
  } catch (e) {
    if (!isAbort(e)) alert(`JSON を読めませんでした (${e})`);
  }
});

// ページのどこにドロップしてもよい
const hasFiles = (e: DragEvent) => e.dataTransfer?.types.includes('Files') ?? false;
addEventListener('dragover', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  document.body.classList.add('dragging');
});
addEventListener('dragleave', (e) => {
  if (e.relatedTarget === null) document.body.classList.remove('dragging');
});
addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  document.body.classList.remove('dragging');
  // DataTransfer はこのイベントの間しか読めないので、ここで受け取っておく
  const handles = fileAccessSupported
    ? [...(e.dataTransfer?.items ?? [])].filter((i) => i.kind === 'file').map((i) => i.getAsFileSystemHandle?.() ?? Promise.resolve(null))
    : [];
  void addFiles([...(e.dataTransfer?.files ?? [])], handles);
});

// ---- クロップの書き出し ----

const outFormat = $<HTMLSelectElement>('out-format');

// 書き出した音源を開く。ループを決めていた音源なら、前を切った分を引いた秒数で項目を作る。元の音源と項目は残す
async function openCropped(out: File, sourceLoop: LoopPoints | undefined, loopStart: number, loopEnd: number) {
  files.set(out.name, out);
  updateFileList();
  let d: Decoded;
  try {
    d = await decode(out.name, out);
  } catch (e) {
    // 保存はできているので、書き出しの失敗とは分けて伝える。Ogg Vorbis は極端に短いとデコードできないことがある
    alert(`${out.name} を保存しましたが、開けませんでした (${e})`);
    return;
  }
  if (sourceLoop) loops[out.name] = { ...sourceLoop, loopStart: round6(loopStart), loopEnd: round6(loopEnd), duration: round6(d.buffer.duration) };
  else delete loops[out.name];   // 同じ名前で置き換えたときに、前の音源の項目を残さない
  setMode('loop');
  select.value = out.name;
  await open(out.name);
}

$('export-crop').addEventListener('click', () => void whileWriting('音源を書き出せませんでした', async () => {
  if (!buffer) return;
  const format = outFormat.value as OutFormat;
  const info = OUT_FORMATS[format];
  if (buffer.numberOfChannels > info.maxChannels) {
    alert(`${info.description} は ${info.maxChannels}ch までです。この音源は ${buffer.numberOfChannels}ch なので、WAV で書き出してください`);
    return;
  }
  const suggested = croppedName(name, format);
  // 保存先の選択はクリックの直後でないと拒否されるので、エンコードより先に開く
  const handle = fileAccessSupported ? await pickAudioToSave(suggested, info) : null;
  // ダイアログを開いている間に変わらないよう、ここで控える
  const source = files.get(name)!, audio = buffer, from = crop.start, to = crop.end;
  const sourceLoop = loops[name], rate = audio.sampleRate, loopStart = (start - from) / rate, loopEnd = (end - from) / rate;
  const { renderCrop } = await import('./cropRender');
  const blob = await renderCrop(source, audio, from, to, format);
  if (handle) await writeContent(handle, blob);
  else downloadBlob(blob, suggested);
  await openCropped(new File([blob], handle?.name ?? suggested, { type: blob.type }), sourceLoop, loopStart, loopEnd);
}));

// ---- 再生 ----

function play(fromSample: number) {
  if (!buffer) return;
  if (mode === 'crop') {
    const from = fromSample >= crop.start && fromSample < crop.end ? fromSample : crop.start;
    player.playOnce(buffer, from / sr(), crop.end / sr());
    return;
  }
  player.play(buffer, fromSample / sr(), start / sr(), end / sr());
}
const preroll = () => Math.max(0, Number($<HTMLInputElement>('preroll').value) || 0);
$('play-intro').addEventListener('click', () => play(mode === 'crop' ? crop.start : 0));
$('play-seam').addEventListener('click', () => {
  const [first, last] = mode === 'crop' ? [crop.start, crop.end] : [0, end];
  play(Math.max(first, last - preroll() * sr()));
});
$('play-cursor').addEventListener('click', () => play(cursor));
$('stop').addEventListener('click', () => player.stop());
$('fit').addEventListener('click', () => view.fit());
const volume = $<HTMLInputElement>('volume');
const applyVolume = () => { player.gain.gain.value = Number(volume.value); };
volume.addEventListener('input', applyVolume);
applyVolume();

// ボタン・チェックボックス・スライダーにフォーカスが残ると、Space でそれが押されるので外す
const isToggle = (t: EventTarget | null) =>
  t instanceof HTMLButtonElement || (t instanceof HTMLInputElement && (t.type === 'checkbox' || t.type === 'range'));
// テーマのボタンは再生と関係がないので、キーボードで操作したときはボタンとして扱う
const isThemeButton = (t: EventTarget | null) => t instanceof Element && t.closest('#theme') !== null;
document.addEventListener('click', (e) => {
  const fromKeyboard = e.detail === 0;
  if (isToggle(e.target) && !(fromKeyboard && isThemeButton(e.target))) (e.target as HTMLElement).blur();
});
addEventListener('keydown', (e) => {
  // 数値の欄とセレクトでは Space を文字入力などに使うので横取りしない
  const typing = (e.target instanceof HTMLInputElement && !isToggle(e.target)) || e.target instanceof HTMLSelectElement;
  if (e.code !== 'Space' || typing || isThemeButton(e.target)) return;
  e.preventDefault();
  if (e.repeat) return;   // 長押しのキーリピートで再生と停止を繰り返さない
  if (player.playing) player.stop();
  else play(cursor);
});

function frame() {
  const t = player.position();
  playhead = t === null ? null : t * sr();
  $('time').textContent = t === null ? '' : formatTime(t);
  view.draw();
  requestAnimationFrame(frame);
}

// ---- 起動 ----

$('info').textContent = '音源をドロップするか、「音源を開く」で選んでください';
setMode('loop');
requestAnimationFrame(frame);
