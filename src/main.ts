import { fetchLoops, fetchSounds, saveLoops, type LoopMap } from './loops';
import { LoopPlayer } from './player';
import { mixdown, nearestZeroCross, nextZeroCross } from './samples';
import { WaveformView, formatTime, type Marker } from './waveform';

// 音源ごとのループポイントを決めるビューア。決めた値は sounds/loops.json に保存し、ゲームから読む
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const SNAP_PX = 10;          // ドラッグ中、この距離 (CSS px) 以内のゼロクロスに吸着する
const ZERO_CROSS_LIMIT = 1;  // 「◀ 0」「0 ▶」で探す範囲 (秒)
const MARKER_ZOOM = 0.02;    // 「拡大」で表示する幅 (秒)

const ctx = new AudioContext();
const player = new LoopPlayer(ctx);
const decoded = new Map<string, { buffer: AudioBuffer; mono: Float32Array }>();

// 開いている音源。位置はサンプル
let name = '';
let buffer: AudioBuffer | null = null;
let mono: Float32Array = new Float32Array(0);
let start = 0, end = 0, cursor = 0;
let playhead: number | null = null;

let loops: LoopMap = {};
let saved: LoopMap = {};   // loops.json にある (と分かっている) 値

const sr = () => buffer?.sampleRate ?? 44100;
const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
// 秒は小数 6 桁で持つ。1 サンプル (44.1kHz で約 23µs) より細かいので、サンプルに戻しても同じ位置になる
const round6 = (v: number) => Math.round(v * 1e6) / 1e6;
// saved から変えた音源の項目だけ。保存ではこれだけを送る
const changed = (): LoopMap => Object.fromEntries(Object.entries(loops).filter(([k, p]) =>
  p.loopStart !== saved[k]?.loopStart || p.loopEnd !== saved[k]?.loopEnd));
const isDirty = () => Object.keys(changed()).length > 0;

const view = new WaveformView($<HTMLCanvasElement>('wave'), $<HTMLCanvasElement>('overview'), () => ({ start, end, cursor, playhead }));

// ---- ループポイント ----

function setMarker(m: Marker, s: number) {
  if (!buffer) return;
  if (m === 'start') start = clamp(Math.round(s), 0, end - 1);
  else end = clamp(Math.round(s), start + 1, buffer.length);
  loops[name] = { loopStart: round6(start / sr()), loopEnd: round6(end / sr()) };
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

// 開始・終了それぞれの数値入力と微調整のボタン
const panels = {} as Record<Marker, { sec: HTMLInputElement; samples: HTMLInputElement }>;
for (const [m, label, color] of [['start', '開始', 'var(--start)'], ['end', '終了', 'var(--end)']] as const) {
  const el = document.createElement('div');
  el.className = 'marker';
  el.style.setProperty('--c', color);
  el.innerHTML = `
    <h2>${label} <button data-act="zoom" title="この点を拡大して表示">拡大</button></h2>
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
  const pos = () => (m === 'start' ? start : end);
  const sec = el.querySelector<HTMLInputElement>('[data-f=sec]')!;
  const samples = el.querySelector<HTMLInputElement>('[data-f=samples]')!;
  panels[m] = { sec, samples };
  // 空や数でない入力は、マーカーを動かさずに表示を戻す (Number('') は 0 になるので跳んでしまう)
  const input = (el: HTMLInputElement, toSample: (v: number) => number) => {
    const v = Number(el.value);
    if (el.value.trim() === '' || !Number.isFinite(v)) updatePanel();
    else setMarker(m, toSample(v));
  };
  sec.addEventListener('change', () => input(sec, (v) => v * sr()));
  samples.addEventListener('change', () => input(samples, (v) => v));
  el.querySelector('[data-act=zoom]')!.addEventListener('click', () => view.zoomTo(pos(), MARKER_ZOOM * sr()));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-n]')) b.addEventListener('click', () => setMarker(m, pos() + Number(b.dataset.n)));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-ms]')) b.addEventListener('click', () => setMarker(m, pos() + Math.round((Number(b.dataset.ms) / 1000) * sr())));
  for (const b of el.querySelectorAll<HTMLButtonElement>('[data-zc]')) {
    b.addEventListener('click', () => {
      const z = nextZeroCross(mono, pos(), Number(b.dataset.zc) as 1 | -1, ZERO_CROSS_LIMIT * sr());
      if (z !== null) setMarker(m, z);
    });
  }
}

function updatePanel() {
  for (const m of ['start', 'end'] as const) {
    const s = m === 'start' ? start : end;
    panels[m].sec.value = (s / sr()).toFixed(6);
    panels[m].samples.value = String(s);
  }
  $('length').textContent = `${formatTime((end - start) / sr())} (${end - start} サンプル)`;
  updateStatus();
}

// ---- 保存 ----

let saving = false;   // 保存中は押し直せないようにする (PUT が重なると loops.json の書き込みが競合する)

function updateStatus() {
  const dirty = isDirty();
  $('status').textContent = saving ? '保存中…' : dirty ? '未保存の変更があります' : 'loops.json と同じ';
  $('status').classList.toggle('dirty', dirty && !saving);
  $<HTMLButtonElement>('save').disabled = !dirty || saving;
}

$('save').addEventListener('click', async () => {
  // PUT の間に変えた分を保存済みと扱わないよう、送る時点の中身を控えておく
  const sent = changed();
  saving = true;
  updateStatus();
  try {
    await saveLoops(sent);
    saved = { ...saved, ...sent };
  } catch (e) {
    alert(String(e));
  } finally {
    saving = false;
    updateStatus();
  }
});
addEventListener('beforeunload', (e) => {
  if (isDirty()) e.preventDefault();
});

// ---- 音源の読み込み ----

let opening = '';   // 読み込み中の音源。読み込み中に別の音源へ切り替えたかを見分ける

async function open(file: string) {
  player.stop();
  playhead = null;
  opening = file;
  // 読み込みが終わるまでは、前の音源のマーカーを動かしたり鳴らしたりできないようにする
  // (name は読み込めてから変える。先に変えると、前の音源の位置が新しい音源の項目に入る)
  buffer = null;
  history.replaceState(null, '', `#${encodeURIComponent(file)}`);
  $('info').textContent = '読み込み中…';
  let d = decoded.get(file);
  if (!d) {
    try {
      const res = await fetch(`/api/audio?name=${encodeURIComponent(file)}`);
      if (!res.ok) throw new Error(`${file} を読めませんでした (${res.status})`);
      const b = await ctx.decodeAudioData(await res.arrayBuffer());
      d = { buffer: b, mono: mixdown(b) };
      decoded.set(file, d);
    } catch (e) {
      if (opening !== file) return;
      // 開けなかったら前の音源に戻す。セレクトも戻すので、同じ音源を選び直せる
      opening = name;
      const prev = decoded.get(name);
      if (prev) { buffer = prev.buffer; mono = prev.mono; }
      $<HTMLSelectElement>('file').value = name;
      history.replaceState(null, '', name ? `#${encodeURIComponent(name)}` : location.pathname);
      $('info').textContent = `${file} を開けませんでした (${e})` + (name ? `。${name} のままです` : '');
      return;
    }
  }
  if (opening !== file) return;
  name = file;
  buffer = d.buffer;
  mono = d.mono;
  // 保存済みの値がなければ全体をループにする (触るまでは loops.json に書かない)
  const p = loops[file];
  start = p ? clamp(Math.round(p.loopStart * sr()), 0, buffer.length - 1) : 0;
  end = p ? clamp(Math.round(p.loopEnd * sr()), start + 1, buffer.length) : buffer.length;
  cursor = 0;
  $('info').textContent = `${buffer.sampleRate} Hz · ${buffer.numberOfChannels}ch · ${formatTime(buffer.duration)} (${buffer.length} サンプル)`;
  view.setData(mono, buffer.sampleRate);
  updatePanel();
}

// ---- 再生 ----

function play(fromSample: number) {
  if (!buffer) return;
  player.play(buffer, fromSample / sr(), start / sr(), end / sr());
}
const preroll = () => Math.max(0, Number($<HTMLInputElement>('preroll').value) || 0);
$('play-intro').addEventListener('click', () => play(0));
$('play-seam').addEventListener('click', () => play(Math.max(0, end - preroll() * sr())));
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
document.addEventListener('click', (e) => {
  if (isToggle(e.target)) (e.target as HTMLElement).blur();
});
addEventListener('keydown', (e) => {
  // 数値の欄とセレクトでは Space を文字入力などに使うので横取りしない
  const typing = (e.target instanceof HTMLInputElement && !isToggle(e.target)) || e.target instanceof HTMLSelectElement;
  if (e.code !== 'Space' || typing) return;
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

const select = $<HTMLSelectElement>('file');
select.addEventListener('change', () => void open(select.value));
try {
  const [files, fromFile] = await Promise.all([fetchSounds(), fetchLoops()]);
  saved = fromFile;
  loops = structuredClone(fromFile);
  for (const f of files) select.add(new Option(f, f));
  // 壊れた # (%E0 など) は無視して先頭の音源を開く
  let fromHash = '';
  try { fromHash = decodeURIComponent(location.hash.slice(1)); } catch { /* 無視 */ }
  if (files.length === 0) $('info').textContent = 'sounds/ に音源がありません';
  else {
    select.value = files.includes(fromHash) ? fromHash : files[0];
    await open(select.value);
  }
} catch (e) {
  $('info').textContent = String(e);
}
requestAnimationFrame(frame);
