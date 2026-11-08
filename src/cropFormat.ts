// クロップの書き出し形式
export type OutFormat = 'wav' | 'mp3' | 'ogg';

export const OUT_FORMATS: Record<OutFormat, { description: string; mime: string; ext: string; maxChannels: number }> = {
  wav: { description: 'WAV', mime: 'audio/wav', ext: '.wav', maxChannels: Infinity },
  mp3: { description: 'MP3', mime: 'audio/mpeg', ext: '.mp3', maxChannels: 2 },
  ogg: { description: 'Ogg Vorbis', mime: 'audio/ogg', ext: '.ogg', maxChannels: 2 },
};

// 拡張子から書き出し形式を決める。書き出せない拡張子は null
export function extFormat(fileName: string): OutFormat | null {
  const ext = /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// 元の形式で書き出せるならその形式、書き出せない形式 (m4a、flac など) は WAV
export const formatOf = (fileName: string): OutFormat => extFormat(fileName) ?? 'wav';

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
