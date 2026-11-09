// クロップの書き出し形式。mp3 の音源は再エンコードせずに mp3 で切り出せる。WAV はどの音源からも書き出せる
export type OutFormat = 'wav' | 'mp3';

export const OUT_FORMATS: Record<OutFormat, { label: string; description: string; mime: string; ext: string }> = {
  mp3: { label: 'mp3 (無劣化)', description: 'MP3', mime: 'audio/mpeg', ext: '.mp3' },
  wav: { label: 'WAV', description: 'WAV', mime: 'audio/wav', ext: '.wav' },
};

// 拡張子から形式を決める。どちらでもなければ null
export function extFormat(fileName: string): OutFormat | null {
  const ext = /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// 音源から書き出せる形式。先頭が初期値。mp3 は mp3 と WAV、それ以外は WAV だけ
export const formatsFor = (fileName: string): OutFormat[] => (extFormat(fileName) === 'mp3' ? ['mp3', 'wav'] : ['wav']);

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
