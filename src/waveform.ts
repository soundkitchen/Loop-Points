// 波形の表示と、マーカーのドラッグ・拡大縮小・スクロール
export type Marker = 'start' | 'end';

// 描くたびに main から受け取る値 (位置はすべてサンプル)
export interface WaveState {
  start: number;
  end: number;
  cursor: number;
  playhead: number | null;
}

const RULER = 20;        // 上の目盛りの高さ (CSS px)
const HIT = 7;           // マーカーをつかめる距離 (CSS px)
const MAX_PX_PER_SAMPLE = 64;
// Canvas の色は index.html の CSS 変数で決める。テーマが変わったら refreshColors で読み直す
const COLOR_VARS = {
  bg: '--wave-bg',
  ruler: '--wave-ruler',
  tick: '--wave-tick',
  label: '--wave-label',
  zero: '--wave-zero',
  wave: '--wave-in',
  waveOut: '--wave-out',    // ループ区間の外
  region: '--wave-region',
  start: '--start',
  end: '--end',
  cursor: '--wave-cursor',
  playhead: '--wave-playhead',
  view: '--wave-view',
  flagText: '--wave-flag-text',
};
const COLOR = {} as Record<keyof typeof COLOR_VARS, string>;

// 目盛りの間隔の候補 (秒)
const TICK_STEPS = [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60];

export function formatTime(sec: number, digits = 3) {
  const m = Math.floor(sec / 60);
  const s = sec - m * 60;
  return `${m}:${s.toFixed(digits).padStart(digits > 0 ? digits + 3 : 2, '0')}`;
}

// 一定の範囲の波形を、1 列ずつ最小〜最大の縦線で描く。1 サンプルが 1 列より広くなったら線でつなぎ、さらに広がったら点も打つ
function drawWave(g: CanvasRenderingContext2D, d: Float32Array, x0: number, spp: number, w: number, top: number, h: number, colorAt: (i: number) => string) {
  const mid = top + h / 2, amp = (h / 2) * 0.92;
  if (spp >= 1) {
    for (let x = 0; x < w; x++) {
      const a = Math.max(0, Math.floor(x0 + x * spp));
      const b = Math.min(d.length, Math.max(a + 1, Math.floor(x0 + (x + 1) * spp)));
      if (a >= d.length) break;
      let lo = Infinity, hi = -Infinity;
      for (let i = a; i < b; i++) {
        const v = d[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      if (hi < lo) continue;
      g.fillStyle = colorAt(a);
      g.fillRect(x, mid - hi * amp, 1, Math.max(1, (hi - lo) * amp));
    }
    return;
  }
  const i0 = Math.max(0, Math.floor(x0) - 1), i1 = Math.min(d.length - 1, Math.ceil(x0 + w * spp) + 1);
  const px = 1 / spp;
  g.lineWidth = Math.max(1, Math.min(2, px / 8));
  for (let i = i0; i < i1; i++) {
    g.strokeStyle = colorAt(i);
    g.beginPath();
    g.moveTo((i - x0) * px, mid - d[i] * amp);
    g.lineTo((i + 1 - x0) * px, mid - d[i + 1] * amp);
    g.stroke();
  }
  if (px >= 6) {
    const r = Math.min(3, px / 5);
    for (let i = i0; i <= i1; i++) {
      g.fillStyle = colorAt(i);
      g.fillRect((i - x0) * px - r, mid - d[i] * amp - r, r * 2, r * 2);
    }
  }
}

function fitCanvas(c: HTMLCanvasElement) {
  const dpr = devicePixelRatio;
  const w = Math.round(c.clientWidth * dpr), h = Math.round(c.clientHeight * dpr);
  if (c.width === w && c.height === h) return false;
  c.width = w;
  c.height = h;
  return true;
}

export class WaveformView {
  onMarkerDrag?: (m: Marker, sample: number, samplesPerPx: number) => void;
  onCursor?: (sample: number) => void;

  private data: Float32Array = new Float32Array(0);
  private sampleRate = 44100;
  private viewStart = 0;         // 左端のサンプル
  private spp = 1;               // CSS 1px あたりのサンプル数
  private cache = document.createElement('canvas');        // 波形と目盛り (表示範囲が変わったときだけ描き直す)
  private overviewCache = document.createElement('canvas'); // 全体の波形
  private dirty = true;
  private overviewDirty = true;
  private drag: { kind: 'marker'; marker: Marker } | { kind: 'pan'; x: number; viewStart: number; moved: boolean } | null = null;

  constructor(private canvas: HTMLCanvasElement, private overview: HTMLCanvasElement, private state: () => WaveState) {
    new ResizeObserver(() => { this.dirty = this.overviewDirty = true; }).observe(canvas);
    canvas.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
    canvas.addEventListener('pointerdown', (e) => this.onPointerDown(e));
    canvas.addEventListener('pointermove', (e) => this.onPointerMove(e));
    canvas.addEventListener('pointerup', (e) => this.onPointerUp(e));
    canvas.addEventListener('pointercancel', () => { this.drag = null; });
    // 全体表示はクリック・ドラッグした所を中心に表示する
    const seek = (e: PointerEvent) => {
      const r = this.overview.getBoundingClientRect();
      this.centerOn(((e.clientX - r.left) / r.width) * this.data.length);
    };
    overview.addEventListener('pointerdown', (e) => { overview.setPointerCapture(e.pointerId); seek(e); });
    overview.addEventListener('pointermove', (e) => { if (overview.hasPointerCapture(e.pointerId)) seek(e); });
  }

  private get width() { return this.canvas.clientWidth; }

  // CSS 変数から色を読み直し、波形を描き直す
  refreshColors() {
    const style = getComputedStyle(document.documentElement);
    for (const [key, cssVar] of Object.entries(COLOR_VARS)) {
      COLOR[key as keyof typeof COLOR_VARS] = style.getPropertyValue(cssVar).trim();
    }
    this.dirty = this.overviewDirty = true;
  }

  setData(data: Float32Array, sampleRate: number) {
    this.data = data;
    this.sampleRate = sampleRate;
    this.overviewDirty = true;
    this.fit();
  }

  // 全体を表示
  fit() {
    this.spp = this.data.length / Math.max(1, this.width);
    this.viewStart = 0;
    this.dirty = true;
  }

  // サンプル pos を中心に、幅 span サンプルを表示
  zoomTo(pos: number, span: number) {
    this.spp = span / Math.max(1, this.width);
    this.centerOn(pos);
  }

  centerOn(pos: number) {
    this.viewStart = pos - (this.width * this.spp) / 2;
    this.clamp();
  }

  private clamp() {
    const w = Math.max(1, this.width);
    this.spp = Math.min(Math.max(this.spp, 1 / MAX_PX_PER_SAMPLE), this.data.length / w);
    const maxStart = this.data.length - w * this.spp;
    this.viewStart = Math.min(Math.max(this.viewStart, 0), Math.max(0, maxStart));
    this.dirty = true;
  }

  private xToSample(clientX: number) {
    const x = clientX - this.canvas.getBoundingClientRect().left;
    return this.viewStart + x * this.spp;
  }

  private sampleToX(s: number) { return (s - this.viewStart) / this.spp; }

  private hitMarker(clientX: number): Marker | null {
    const x = clientX - this.canvas.getBoundingClientRect().left;
    const { start, end } = this.state();
    const ds = Math.abs(this.sampleToX(start) - x), de = Math.abs(this.sampleToX(end) - x);
    if (Math.min(ds, de) > HIT) return null;
    return ds <= de ? 'start' : 'end';
  }

  private onWheel(e: WheelEvent) {
    e.preventDefault();
    if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) {
      this.viewStart += e.deltaX * this.spp;
    } else {
      // 縦のホイールで拡大縮小 (トラックパッドのピンチは ctrlKey 付きで細かく来る)
      const anchor = this.xToSample(e.clientX);
      const k = Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
      const x = e.clientX - this.canvas.getBoundingClientRect().left;
      this.spp *= k;
      this.clamp();
      this.viewStart = anchor - x * this.spp;
    }
    this.clamp();
  }

  private onPointerDown(e: PointerEvent) {
    this.canvas.setPointerCapture(e.pointerId);
    const marker = this.hitMarker(e.clientX);
    this.drag = marker ? { kind: 'marker', marker } : { kind: 'pan', x: e.clientX, viewStart: this.viewStart, moved: false };
  }

  private onPointerMove(e: PointerEvent) {
    const d = this.drag;
    if (!d) {
      this.canvas.style.cursor = this.hitMarker(e.clientX) ? 'ew-resize' : 'default';
      return;
    }
    if (d.kind === 'marker') {
      this.onMarkerDrag?.(d.marker, Math.round(this.xToSample(e.clientX)), this.spp);
    } else {
      if (Math.abs(e.clientX - d.x) > 3) d.moved = true;
      if (d.moved) {
        this.canvas.style.cursor = 'grabbing';
        this.viewStart = d.viewStart - (e.clientX - d.x) * this.spp;
        this.clamp();
      }
    }
  }

  private onPointerUp(e: PointerEvent) {
    const d = this.drag;
    this.drag = null;
    this.canvas.style.cursor = 'default';
    // 動かさずに離したらカーソル (「カーソルから再生」の位置) を置く
    if (d?.kind === 'pan' && !d.moved) {
      this.onCursor?.(Math.min(Math.max(0, Math.round(this.xToSample(e.clientX))), this.data.length));
    }
  }

  // 波形と目盛りを cache に描く
  private renderCache(start: number, end: number) {
    const c = this.cache, dpr = devicePixelRatio;
    c.width = this.canvas.width;
    c.height = this.canvas.height;
    const g = c.getContext('2d')!;
    const w = c.width, h = c.height, ruler = RULER * dpr;
    g.fillStyle = COLOR.bg;
    g.fillRect(0, 0, w, h);
    g.fillStyle = COLOR.ruler;
    g.fillRect(0, 0, w, ruler);
    g.fillStyle = COLOR.zero;
    g.fillRect(0, Math.round(ruler + (h - ruler) / 2), w, 1);
    const inLoop = (i: number) => (i >= start && i < end ? COLOR.wave : COLOR.waveOut);
    drawWave(g, this.data, this.viewStart, this.spp / dpr, w, ruler, h - ruler, inLoop);

    // 目盛り: ラベル同士が 90px 以上離れる、いちばん細かい間隔
    const secPerPx = this.spp / this.sampleRate;
    const step = TICK_STEPS.find((s) => s / secPerPx >= 90) ?? 60;
    const digits = Math.max(0, Math.min(4, Math.ceil(-Math.log10(step) - 1e-9)));
    const t0 = this.viewStart / this.sampleRate, t1 = t0 + this.width * secPerPx;
    g.font = `${11 * dpr}px ui-monospace, monospace`;
    g.textBaseline = 'middle';
    for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) {
      const x = Math.round(((t - t0) / secPerPx) * dpr);
      g.fillStyle = COLOR.tick;
      g.fillRect(x, ruler - 6 * dpr, 1, 6 * dpr);
      g.fillStyle = COLOR.label;
      g.fillText(formatTime(t, digits), x + 4 * dpr, ruler / 2 - 1 * dpr);
    }
  }

  private renderOverviewCache() {
    const c = this.overviewCache;
    c.width = this.overview.width;
    c.height = this.overview.height;
    const g = c.getContext('2d')!;
    g.fillStyle = COLOR.bg;
    g.fillRect(0, 0, c.width, c.height);
    drawWave(g, this.data, 0, this.data.length / Math.max(1, c.width), c.width, 0, c.height, () => COLOR.waveOut);
  }

  // 毎フレーム呼ぶ。重い波形は cache から写し、マーカーと再生位置だけ描き足す
  draw() {
    if (fitCanvas(this.canvas)) { this.clamp(); this.dirty = true; }
    if (fitCanvas(this.overview)) this.overviewDirty = true;
    if (this.data.length === 0) return;
    const st = this.state();
    const key = `${st.start}:${st.end}`;
    if (this.dirty || key !== this.lastKey) {
      this.renderCache(st.start, st.end);
      this.dirty = false;
      this.lastKey = key;
    }
    if (this.overviewDirty) {
      this.renderOverviewCache();
      this.overviewDirty = false;
    }
    this.drawMain(st);
    this.drawOverview(st);
  }
  private lastKey = '';

  private drawMain(st: WaveState) {
    const g = this.canvas.getContext('2d')!, dpr = devicePixelRatio;
    const h = this.canvas.height, ruler = RULER * dpr;
    g.drawImage(this.cache, 0, 0);
    const X = (s: number) => Math.round(this.sampleToX(s) * dpr);

    g.fillStyle = COLOR.region;
    g.fillRect(X(st.start), ruler, X(st.end) - X(st.start), h - ruler);

    const line = (s: number, color: string, width: number, dash: number[] = []) => {
      g.strokeStyle = color;
      g.lineWidth = width * dpr;
      g.setLineDash(dash.map((v) => v * dpr));
      g.beginPath();
      g.moveTo(X(s) + 0.5, 0);
      g.lineTo(X(s) + 0.5, h);
      g.stroke();
      g.setLineDash([]);
    };
    line(st.cursor, COLOR.cursor, 1, [4, 4]);
    for (const [s, color, label] of [[st.start, COLOR.start, '開始'], [st.end, COLOR.end, '終了']] as const) {
      line(s, color, 2);
      g.fillStyle = color;
      g.font = `bold ${11 * dpr}px system-ui, sans-serif`;
      g.textBaseline = 'middle';
      const tw = g.measureText(label).width + 8 * dpr;
      // 旗は開始なら右、終了なら左に出して、区間の内側を向ける
      const fx = label === '開始' ? X(s) : X(s) - tw;
      g.fillRect(fx, 0, tw, ruler);
      g.fillStyle = COLOR.flagText;
      g.fillText(label, fx + 4 * dpr, ruler / 2);
    }
    if (st.playhead !== null) line(st.playhead, COLOR.playhead, 1.5);
  }

  private drawOverview(st: WaveState) {
    const g = this.overview.getContext('2d')!;
    const w = this.overview.width, h = this.overview.height;
    const X = (s: number) => Math.round((s / this.data.length) * w);
    g.drawImage(this.overviewCache, 0, 0);
    g.fillStyle = COLOR.region;
    g.fillRect(X(st.start), 0, X(st.end) - X(st.start), h);
    g.fillStyle = COLOR.start;
    g.fillRect(X(st.start), 0, 2, h);
    g.fillStyle = COLOR.end;
    g.fillRect(X(st.end) - 2, 0, 2, h);
    if (st.playhead !== null) {
      g.fillStyle = COLOR.playhead;
      g.fillRect(X(st.playhead), 0, 1, h);
    }
    // 上の波形に表示している範囲
    g.strokeStyle = COLOR.view;
    g.lineWidth = 2;
    g.fillStyle = COLOR.view;
    const vx = X(this.viewStart), vw = Math.max(2, X(this.viewStart + this.width * this.spp) - vx);
    g.globalAlpha = 0.35;
    g.fillRect(vx, 0, vw, h);
    g.globalAlpha = 1;
    g.strokeRect(vx + 1, 1, vw - 2, h - 2);
  }
}
