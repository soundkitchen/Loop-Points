// 波形の表示とゼロクロスの検出に使う、全チャンネルを平均したモノラルの波形
export function mixdown(buffer: AudioBuffer): Float32Array {
  const out = new Float32Array(buffer.length);
  for (let c = 0; c < buffer.numberOfChannels; c++) {
    const d = buffer.getChannelData(c);
    for (let i = 0; i < d.length; i++) out[i] += d[i];
  }
  const k = 1 / buffer.numberOfChannels;
  for (let i = 0; i < out.length; i++) out[i] *= k;
  return out;
}

// サンプル i-1 と i の間で波形が 0 を横切るか。無音 (ちょうど 0) の所はどこでもつなげるので、横切ったとみなす
// ループの開始と終了をどちらも i の側に置くと、つなぎ目は d[終了-1] → d[開始] と 0 をまたいで続く
function crossesAt(d: Float32Array, i: number) {
  const a = d[i - 1], b = d[i];
  return b === 0 || (a < 0) !== (b < 0);
}

// pos から前後 radius サンプル以内で、いちばん近いゼロクロス
export function nearestZeroCross(d: Float32Array, pos: number, radius: number): number | null {
  for (let r = 0; r <= radius; r++) {
    const a = pos - r, b = pos + r;
    if (a >= 1 && a < d.length && crossesAt(d, a)) return a;
    if (b >= 1 && b < d.length && crossesAt(d, b)) return b;
  }
  return null;
}

// pos から dir の向きに進んで、次のゼロクロス (limit サンプルまで探す)
export function nextZeroCross(d: Float32Array, pos: number, dir: 1 | -1, limit: number): number | null {
  for (let i = pos + dir, n = 0; i >= 1 && i < d.length && n < limit; i += dir, n++) {
    if (crossesAt(d, i)) return i;
  }
  return null;
}
