// ループポイント。AudioBufferSourceNode の loopStart / loopEnd にそのまま渡せるよう秒で持つ
// (サンプル数だと、AudioContext のサンプルレートが変わったときにずれる)
export interface LoopPoints {
  loopStart: number;
  loopEnd: number;
}
export type LoopMap = Record<string, LoopPoints>;

export async function fetchSounds(): Promise<string[]> {
  const res = await fetch('/api/sounds');
  if (!res.ok) throw new Error(`音源の一覧を読めませんでした (${res.status})`);
  return res.json();
}

export async function fetchLoops(): Promise<LoopMap> {
  const res = await fetch('/api/loops');
  if (!res.ok) throw new Error(`loops.json を読めませんでした (${res.status})`);
  return res.json();
}

export async function saveLoops(loops: LoopMap) {
  const res = await fetch('/api/loops', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(loops),
  });
  if (!res.ok) throw new Error(`保存できませんでした (${res.status})`);
}
