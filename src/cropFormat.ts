// クロップの書き出し形式。mp3 と FLAC の音源は、再エンコードせずに元の形式で切り出せる。WAV はどの音源からも書き出せる
export type OutFormat = 'wav' | 'mp3' | 'flac';

export const OUT_FORMATS: Record<OutFormat, { label: string; description: string; mime: string; ext: string }> = {
  mp3: { label: 'mp3 (無劣化)', description: 'MP3', mime: 'audio/mpeg', ext: '.mp3' },
  flac: { label: 'FLAC (無劣化)', description: 'FLAC', mime: 'audio/flac', ext: '.flac' },
  wav: { label: 'WAV', description: 'WAV', mime: 'audio/wav', ext: '.wav' },
};

// 拡張子から形式を決める。どれでもなければ null
export function extFormat(fileName: string): OutFormat | null {
  const ext = /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// 音源から書き出せる形式。先頭が初期値。native は元の形式のまま切り出せる形式 (mp3 か FLAC) で、
// その形式と WAV を選べる。それ以外 (null や WAV) は WAV だけ。
// kiln が中身を調べる前は拡張子から、調べた後は kiln の結果から native を決める (cropRender.ts の inspect)
export const formatsFor = (native: OutFormat | null): OutFormat[] => (native === 'mp3' || native === 'flac' ? [native, 'wav'] : ['wav']);

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
