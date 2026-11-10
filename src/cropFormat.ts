// クロップの書き出し形式。mp3、FLAC、Ogg Opus の音源は、再エンコードせずに元の形式で切り出せる。WAV はどの音源からも書き出せる。
// opus と ogg はどちらも Ogg Opus で、拡張子だけが違う (元の音源の拡張子に合わせる)
export type OutFormat = 'wav' | 'mp3' | 'flac' | 'opus' | 'ogg';

export const OUT_FORMATS: Record<OutFormat, { label: string; description: string; mime: string; ext: string }> = {
  mp3: { label: 'mp3 (無劣化)', description: 'MP3', mime: 'audio/mpeg', ext: '.mp3' },
  flac: { label: 'FLAC (無劣化)', description: 'FLAC', mime: 'audio/flac', ext: '.flac' },
  opus: { label: 'Opus (無劣化)', description: 'Opus', mime: 'audio/ogg', ext: '.opus' },
  ogg: { label: 'Ogg (無劣化)', description: 'Ogg', mime: 'audio/ogg', ext: '.ogg' },
  wav: { label: 'WAV', description: 'WAV', mime: 'audio/wav', ext: '.wav' },
};

// 拡張子から形式を決める。どれでもなければ null
export function extFormat(fileName: string): OutFormat | null {
  const ext = /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// 音源から書き出せる形式。先頭が初期値。native は元の形式のまま切り出せる形式 (mp3、FLAC、Ogg Opus) で、
// その形式と WAV を選べる。それ以外 (null や WAV) は WAV だけ。
// kiln が中身を調べる前は拡張子から、調べた後は kiln の結果から native を決める (cropRender.ts の inspect)
export const formatsFor = (native: OutFormat | null): OutFormat[] => (native && native !== 'wav' ? [native, 'wav'] : ['wav']);

// 同じ中身で拡張子だけが違う形式か (Ogg Opus の .opus と .ogg)
export const sameContent = (a: OutFormat, b: OutFormat) => a === b || (isOgg(a) && isOgg(b));
export const isOgg = (f: OutFormat) => f === 'opus' || f === 'ogg';

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
