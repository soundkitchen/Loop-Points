import { OUT_FORMATS, croppedName, extFormat, formatsFor, sameContent, type OutFormat } from './cropFormat';
import type { CropSource } from './cropRender';
import { canWrite, isAbort, pickAudioToSave, pickJsonToOpen, pickJsonToSave, writeContent } from './jsonFile';
import { parseLoops, serializeLoops, type LoopMap, type LoopPoints } from './loops';
import { LoopPlayer } from './player';
import { mixdown, nearestZeroCross, nextZeroCross } from './samples';
import { setupTheme } from './theme';
import { MODE_MARKERS, WaveformView, formatTime, type Marker, type Mode } from './waveform';

// 音源ごとのループポイントを決めるビューア。音源はブラウザ内で読み、決めた値は JSON に書き出す
// クロップモードでは音源の前後を切り落として、音源のファイルに書き出す
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const SNAP_PX = 10;          // ドラッグ中、この距離 (CSS px) 以内のゼロクロスに吸着する
const ZERO_CROSS_LIMIT = 1;  // 「◀ 0」「0 ▶」で探す範囲 (秒)
const MARKER_ZOOM = 0.02;    // 「拡大」で表示する幅 (秒)
// duration の不一致とみなす差 (秒)。サンプルレートの違いによる丸めは無視し、mp3 の無音 (数十ミリ秒) の差は拾う
const DURATION_TOLERANCE = 0.001;
// 読み込める音源の拡張子。判定、ファイル選択の accept、案内の文言をここから作る
const AUDIO_EXTS = ['mp3', 'wav', 'ogg', 'opus', 'm4a', 'aac', 'flac'];
const AUDIO_EXT = new RegExp(`\\.(${AUDIO_EXTS.join('|')})$`, 'i');
const JSON_EXT = /\.json$/i;
const SHIFT_NOTICE = 0.001;  // 無劣化の mp3 と Ogg Vorbis で、切り始めが指定とこれ (秒) 以上ずれたら知らせる

const player = new LoopPlayer();
const files = new Map<string, File>();   // 読み込んだ音源。キーはファイル名で、JSON の項目と対応する
type Crop = { start: number; end: number };   // クロップの範囲 (サンプル)。音源ごとに持ち、ファイルを読み直すと全体に戻る
// buffer は音源の元のサンプルレートのまま。converted は、元のレートが分からず、出力の機器のレートに変換してデコードしたもの
type Decoded = { source: File; buffer: AudioBuffer; mono: Float32Array; crop: Crop; converted: boolean };
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
// クロップモードで開いている音源を kiln で調べた結果。調べ終わるまでは null で、書き出せない
let cropSource: CropSource | null = null;
let cropError: string | null = null;
let inspecting: File | undefined;   // 調べている (調べ終えた) 音源

let loops: LoopMap = {};
let saved: LoopMap = {};   // 読み込んだ、または最後に書き出した JSON の値
// 上書き保存の対象。lastModified は外からの変更に気づくために控える。JSON を読み込むか保存するまでは null
let jsonTarget: { handle: FileSystemFileHandle; lastModified: number } | null = null;
let writing = false;       // 保存ダイアログを開いている間と書き込み中。この間は保存も JSON の読み込みもしない

const sr = () => buffer?.sampleRate ?? 44100;
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
// 秒は小数 6 桁で持つ。1 サンプル (44.1kHz で約 23µs) より細かいので、サンプルに戻しても同じ位置になる
const round6 = (v: number) => Math.round(v * 1e6) / 1e6;
// 消した項目も変更に含める。クロップで同じ名前の音源を置き換えると、項目を消すことがある
const isDirty = () => Object.keys(saved).some((k) => !(k in loops)) || Object.entries(loops).some(([k, p]) =>
  p.loopStart !== saved[k]?.loopStart || p.loopEnd !== saved[k]?.loopEnd || p.duration !== saved[k]?.duration);
const outFormat = $<HTMLSelectElement>('out-format');
// 実際に切り始める位置 (サンプル)。長さの情報のない mp3 は、無劣化では先頭の 529 サンプルより前から切れない
const cropFrom = (format: OutFormat) => (format === 'mp3' && cropSource ? Math.max(crop.start, cropSource.mp3Start * sr()) : crop.start);
// ループを決めた音源で、クロップの範囲がループ区間にかかっているか。決めていない音源は全体が区間なので対象にしない
const cropCutsLoop = (format = outFormat.value as OutFormat) => loops[name] !== undefined && (cropFrom(format) > start || crop.end < end);

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

// 数値入力と微調整のボタンは、今のモードで動かす 2 本の線 (MODE_MARKERS) に対応する
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
  // 音源を開くまでは空欄にする
  MODE_MARKERS[mode].forEach((m, i) => {
    const s = positionOf(m);
    panels[i].sec.value = buffer ? (s / sr()).toFixed(6) : '';
    panels[i].samples.value = buffer ? String(s) : '';
  });
  const [a, z] = mode === 'crop' ? [crop.start, crop.end] : [start, end];
  $('length').textContent = buffer ? `${formatTime((z - a) / sr())} (${z - a} サンプル)` : '';
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
  inspectCropSource();
  updatePanel();
}

// クロップモードで開いている音源を、保存先を選ぶ前に kiln で調べ、書き出せる形式と切り始められる位置を決める。
// ループモードに戻ったら、読んだバイト列を手放す
function inspectCropSource() {
  const file = mode === 'crop' && buffer ? files.get(name) : undefined;
  const decoded = buffer;
  if (file === inspecting) return;
  inspecting = file;
  cropSource = null;
  cropError = null;
  updateOutFormats();
  if (!file) return;
  import('./cropRender').then((m) => m.inspect(file, decoded!)).then(
    (s) => { if (inspecting === file) cropSource = s; },
    (e) => { if (inspecting === file) cropError = `${file.name} を書き出す準備ができませんでした (${e})`; },
  ).finally(() => {
    if (inspecting !== file) return;
    updateOutFormats();
    updatePanel();
  });
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
  if (mode === 'crop' && cropError) messages.push(cropError);
  else if (mode === 'crop' && cropSource?.lengthMismatch) {
    messages.push(`${name} は、ブラウザでデコードした長さ (${formatTime(buffer!.duration)}) と FLAC の長さ (${formatTime(cropSource.flac!.duration)}) が違います。壊れたフレームをブラウザが飛ばしていると、波形で選んだ位置と書き出す位置がずれるので、書き出せません`);
  } else if (mode === 'crop' && cropCutsLoop()) {
    messages.push(cropCutsLoop('wav')
      ? 'クロップの範囲がループ区間にかかっているので、書き出せません。線を区間の外へ動かすか、ループモードで区間を動かしてください'
      : `長さの情報のない mp3 は、無劣化では ${formatTime(cropSource!.mp3Start)} より前から切り出せません。ループの開始が削れるので、書き出せません。WAV を選ぶと書き出せます`);
  }
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
  $<HTMLButtonElement>('export-crop').disabled = !buffer || writing || !cropSource || cropSource.lengthMismatch || cropCutsLoop();
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
  // 音源より先に読み込んだときに、読み込めたことを案内に出す
  if (!name) $('empty-json').textContent = `${file.name} を読み込みました (${Object.keys(parsed).length} 件)。音源を開くと反映します`;
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

$('download').addEventListener('click', () => void whileWriting(JSON_FAILURE, async () => {
  const handle = await pickJsonToSave(jsonTarget?.handle.name ?? 'loops.json');
  const sent = structuredClone(loops);
  const lastModified = await writeContent(handle, serializeLoops(sent));
  jsonTarget = { handle, lastModified };
  markExported(sent);
}));

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

// 読み込みの経過を出す。音源を 1 つも開いていないうちはヘッダーが隠れているので、読み込みの案内に出す
const showInfo = (text: string) => { $(name ? 'info' : 'empty-info').textContent = text; };

function decode(file: string, source: File): Promise<Decoded> {
  let pending = decoding.get(source);
  if (!pending) {
    pending = (async () => {
      try {
        // 元のサンプルレートのままデコードする。AudioContext の decodeAudioData はそのコンテキストのレートに変換するので、
        // 変換後の波形で探したゼロクロスや「サンプル」の値が、元のレートで鳴らす側と合わなくなる。
        // 元のレートは kiln で調べる (最初の音源を開くときに kiln を読み込む)。分からなければ出力の機器のレートにする。
        // kiln を読み込めないときや、調べている途中で失敗したときも、ブラウザがデコードできれば開けるよう、同じ扱いにする
        const bytes = await source.arrayBuffer();
        const rate = await import('./sourceDetect').then((m) => m.sourceRate(file, new Uint8Array(bytes))).catch((e) => {
          console.warn(`Could not read the sample rate of ${file}; decoding at the output device rate.`, e);
          return null;
        });
        const b = await new OfflineAudioContext(1, 1, rate ?? player.outputRate).decodeAudioData(bytes);
        const d = { source, buffer: b, mono: mixdown(b), crop: { start: 0, end: b.length }, converted: rate === null };
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
  showInfo('読み込み中…');
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
    showInfo(`${file} を開けませんでした (${e})` + (name ? `。${name} のままです` : ''));
    return 'failed';
  }
  if (token !== openToken) return 'superseded';
  name = file;
  buffer = d.buffer;
  mono = d.mono;
  crop = d.crop;
  cursor = 0;
  updateOutFormats();
  inspectCropSource();
  // 最初に開けたときに編集画面に切り替えて、描画を始める。波形の幅を測れるよう、setData より前に表示する
  if (!document.body.classList.contains('loaded')) {
    document.body.classList.add('loaded');
    requestAnimationFrame(frame);
  }
  showInfo(`${buffer.sampleRate} Hz${d.converted ? ' (変換後)' : ''} · ${buffer.numberOfChannels}ch · ${formatTime(buffer.duration)} (${buffer.length} サンプル)`);
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
audioInput.accept = AUDIO_EXTS.map((ext) => `.${ext}`).join(',');
audioInput.addEventListener('change', () => {
  const picked = [...(audioInput.files ?? [])];
  audioInput.value = '';   // 同じファイルをもう一度選んでも change が起きるように空にする
  void addFiles(picked);
});
async function openJson() {
  // 上書き保存できるよう、ハンドルが取れる方法で開く
  try {
    const handle = await pickJsonToOpen();
    await loadLoops(await handle.getFile(), handle);
  } catch (e) {
    if (!isAbort(e)) alert(`JSON を読めませんでした (${e})`);
  }
}
// ヘッダーのボタンと、音源を開く前の案内のボタン
for (const id of ['open-audio', 'empty-open-audio']) $(id).addEventListener('click', () => audioInput.click());
for (const id of ['open-json', 'empty-open-json']) $(id).addEventListener('click', () => void openJson());

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
  const handles = [...(e.dataTransfer?.items ?? [])].filter((i) => i.kind === 'file').map((i) => i.getAsFileSystemHandle());
  void addFiles([...(e.dataTransfer?.files ?? [])], handles);
});

// ---- クロップの書き出し ----

// 開いている音源で選べる形式を入れる。kiln で調べ終わるまでは拡張子から決め、選べないようにする
function updateOutFormats() {
  // 調べる前の仮の形式。.ogg と .m4a は中身が何か (Opus か Vorbis か、AAC か ALAC かなど) 分からないので、
  // 元の形式は出さない (kiln で調べてから出す)
  const ext = extFormat(name);
  const formats = cropSource?.formats ?? formatsFor(ext === 'ogg' || ext === 'm4a' ? null : ext);
  outFormat.replaceChildren(...formats.map((f) => new Option(OUT_FORMATS[f].label, f)));
  outFormat.disabled = formats.length < 2 || !cropSource;
}
// 形式によって、実際に切り始める位置が変わる
outFormat.addEventListener('change', () => updatePanel());

// 書き出した音源を開く。ループを決めていた音源なら、前を切った分を引いた秒数で項目を作る。元の音源と項目は残す
async function openCropped(out: File, sourceLoop: LoopPoints | undefined, loopStart: number, loopEnd: number) {
  files.set(out.name, out);
  updateFileList();
  let d: Decoded;
  try {
    d = await decode(out.name, out);
  } catch (e) {
    // 保存はできているので、書き出しの失敗とは分けて伝える
    alert(`${out.name} を保存しましたが、開けませんでした (${e})`);
    return;
  }
  // 無劣化の mp3 は切り始めが後ろにずれることがあるので、負にならないようにする (Ogg Vorbis は前にずれるので負にならない)
  if (sourceLoop) loops[out.name] = { ...sourceLoop, loopStart: round6(Math.max(0, loopStart)), loopEnd: round6(loopEnd), duration: round6(d.buffer.duration) };
  else delete loops[out.name];   // 同じ名前で置き換えたときに、前の音源の項目を残さない
  setMode('loop');
  select.value = out.name;
  await open(out.name);
}

$('export-crop').addEventListener('click', () => void whileWriting('音源を書き出せませんでした', async () => {
  // 元のファイルは読み直さず、クロップモードで読んでおいたバイト列から書き出す (CropSource を参照)
  const source = cropSource;
  if (!buffer || !source) return;
  const format = outFormat.value as OutFormat;
  // 保存先の選択はクリックの直後でないと拒否されるので、書き出しの処理より先に開く
  const handle = await pickAudioToSave(croppedName(name, format), OUT_FORMATS[format]);
  // 書き出しの処理の間に変わらないよう、ここで控える
  const audio = buffer, from = crop.start, to = crop.end;
  const sourceLoop = loops[name], rate = audio.sampleRate, loopStart = start / rate, loopEnd = end / rate;
  // 拡張子と中身が食い違うと、開き直したときやゲームエンジンで形式を読み違えるので、この音源から書ける形式なら、
  // 選んだ名前の拡張子の形式で書く。ただし、その形式でループの開始が削れるならセレクトの形式で書く。
  // 書き出しを止めると、保存先を選んだ時点で Chromium が作った空のファイル (既存のファイルなら空にしたもの) が残る
  const named = extFormat(handle.name);
  // Ogg Opus は、.opus と .ogg のどちらの名前でも書ける
  const writable = (f: OutFormat) => source.formats.some((g) => sameContent(f, g, source.ogg?.codec === 'opus'));
  const written = named && writable(named) && !cropCutsLoop(named) ? named : format;
  const { renderCrop } = await import('./cropRender');
  const out = await renderCrop(source, audio, from, to, written);
  await writeContent(handle, out.blob);
  const notes: string[] = [];
  if (named !== written) notes.push(`${handle.name} に ${OUT_FORMATS[written].description} で保存しました。拡張子が ${OUT_FORMATS[written].ext} でないので、開くときに形式を読み違えることがあります`);
  // 長さの情報のない mp3 は、先頭のデコーダの遅延 (529 サンプル) より前を無劣化では切れない
  if (written === 'mp3' && out.start - from / rate >= SHIFT_NOTICE) notes.push(`mp3 の先頭は無劣化では切り出せないので、${formatTime(out.start)} から切り出しました`);
  // Ogg Vorbis は、先頭をパケットの区切り (指定より前) に寄せて切り出す
  if (written === 'ogg' && source.ogg?.codec === 'vorbis' && from / rate - out.start >= SHIFT_NOTICE) notes.push(`Ogg Vorbis の先頭は無劣化ではパケットの区切りでしか切り出せないので、少し前の ${formatTime(out.start)} から切り出しました`);
  // kiln は壊れたフレームを無音で埋めて長さを保つが、ブラウザのデコードは飛ばすことがあるので、波形の位置とずれうる
  if (out.invalidFrames > 0) notes.push(`壊れていたフレームが ${out.invalidFrames} 個あったので、その部分は無音にして書き出しました。ブラウザは壊れたフレームを飛ばして表示することがあるので、その後ろでは、波形で選んだ位置と書き出した位置がずれていることがあります`);
  if (notes.length > 0) alert(notes.join('\n'));
  await openCropped(new File([out.blob], handle.name, { type: out.blob.type }), sourceLoop, loopStart - out.start, loopEnd - out.start);
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
const applyVolume = () => { player.setVolume(Number(volume.value)); };
volume.addEventListener('input', applyVolume);
applyVolume();

// ボタン・チェックボックス・スライダーにフォーカスが残ると、Space でそれが押されるので外す
const isToggle = (t: EventTarget | null) =>
  t instanceof HTMLButtonElement || (t instanceof HTMLInputElement && (t.type === 'checkbox' || t.type === 'range'));
// 配色とモードのボタンは再生と関係がないので、キーボードで操作したときはボタンとして扱う
const isSwitchButton = (t: EventTarget | null) => t instanceof Element && t.closest('#theme, #mode') !== null;
document.addEventListener('click', (e) => {
  const fromKeyboard = e.detail === 0;
  if (isToggle(e.target) && !(fromKeyboard && isSwitchButton(e.target))) (e.target as HTMLElement).blur();
});
addEventListener('keydown', (e) => {
  // 数値の欄とセレクトでは Space を文字入力などに使うので横取りしない。
  // 音源を開くまでは鳴らすものがなく、案内のボタンを Space で押せるよう横取りしない
  const typing = (e.target instanceof HTMLInputElement && !isToggle(e.target)) || e.target instanceof HTMLSelectElement;
  if (e.code !== 'Space' || typing || isSwitchButton(e.target) || !name) return;
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

// 描画は、最初の音源を開いたときに open が始める
$('audio-formats').textContent = AUDIO_EXTS.join(' / ');
setMode('loop');
