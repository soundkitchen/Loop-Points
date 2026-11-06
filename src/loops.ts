// ループポイント。AudioBufferSourceNode の loopStart / loopEnd にそのまま渡せるよう秒で持つ
// (サンプル数だと、AudioContext のサンプルレートが変わったときにずれる)
export interface LoopPoints {
  loopStart: number;
  loopEnd: number;
  duration?: number;   // デコード後の長さ (秒)。音源の取り違えに気づくために記録する。古い JSON にはない
}
export type LoopMap = Record<string, LoopPoints>;

// JSON を読んで形を確かめる。ファイル名ごとに loopStart < loopEnd (秒) を持つ。おかしな項目があれば全体を読まない
export function parseLoops(text: string): LoopMap {
  const v: unknown = JSON.parse(text);
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new Error('ファイル名ごとのオブジェクトではありません');
  return Object.fromEntries(Object.entries(v).map(([name, p]): [string, LoopPoints] => {
    const { loopStart, loopEnd, duration } = (p ?? {}) as Record<string, unknown>;
    if (typeof loopStart !== 'number' || typeof loopEnd !== 'number' || !Number.isFinite(loopStart) || !Number.isFinite(loopEnd) || loopStart < 0 || loopStart >= loopEnd) {
      throw new Error(`${name} の loopStart / loopEnd が正しくありません`);
    }
    if (duration === undefined) return [name, { loopStart, loopEnd }];
    if (typeof duration !== 'number' || !Number.isFinite(duration) || duration <= 0) throw new Error(`${name} の duration が正しくありません`);
    return [name, { loopStart, loopEnd, duration }];
  }));
}

// 差分が読みやすいよう、ファイル名の順に並べて書く
export function serializeLoops(loops: LoopMap): string {
  const sorted = Object.fromEntries(Object.keys(loops).sort().map((k) => [k, loops[k]]));
  return JSON.stringify(sorted, null, 2) + '\n';
}
