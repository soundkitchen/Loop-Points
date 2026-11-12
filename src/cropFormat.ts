// クロップの書き出し形式。mp3、FLAC、Ogg (Opus、Vorbis)、m4a (AAC) の音源は、再エンコードせずに元の形式で切り出せる。
// WAV と FLAC はどの音源からも書き出せる (FLAC の音源以外は、デコードして FLAC にエンコードする)。
// opus は Ogg Opus。ogg は Ogg Opus か Ogg Vorbis (元の音源と同じ中身)。Ogg Opus は元の音源の拡張子に合わせる
export type OutFormat = 'wav' | 'mp3' | 'flac' | 'opus' | 'ogg' | 'm4a';

export const OUT_FORMATS: Record<OutFormat, { label: string; description: string; mime: string; ext: string }> = {
  mp3: { label: 'mp3 (無劣化)', description: 'MP3', mime: 'audio/mpeg', ext: '.mp3' },
  flac: { label: 'FLAC (無劣化)', description: 'FLAC', mime: 'audio/flac', ext: '.flac' },
  opus: { label: 'Opus (無劣化)', description: 'Opus', mime: 'audio/ogg', ext: '.opus' },
  ogg: { label: 'Ogg (無劣化)', description: 'Ogg', mime: 'audio/ogg', ext: '.ogg' },
  m4a: { label: 'm4a (無劣化)', description: 'm4a', mime: 'audio/mp4', ext: '.m4a' },
  wav: { label: 'WAV', description: 'WAV', mime: 'audio/wav', ext: '.wav' },
};

// 拡張子から形式を決める。どれでもなければ null
export function extFormat(fileName: string): OutFormat | null {
  const ext = /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// kiln の FLAC のエンコーダーが書けるチャンネル数の上限 (FLAC の仕様の上限)
const FLAC_MAX_CHANNELS = 8;

// 音源から書き出せる形式。先頭が初期値。native は元の形式のまま切り出せる形式 (mp3、FLAC、Ogg、m4a) で、
// その形式、WAV、FLAC の順に並べる (FLAC の音源は FLAC と WAV)。それ以外 (null や WAV) は WAV と FLAC。
// ただし、9 チャンネル以上の音源は FLAC にできないので、FLAC を除く。
// kiln が中身を調べる前は拡張子から、調べた後は kiln の結果から native を決める (cropRender.ts の inspect)
export function formatsFor(native: OutFormat | null, channels: number): OutFormat[] {
  if (native === 'flac') return ['flac', 'wav'];
  const formats: OutFormat[] = native && native !== 'wav' ? [native, 'wav', 'flac'] : ['wav', 'flac'];
  return channels > FLAC_MAX_CHANNELS ? formats.filter((f) => f !== 'flac') : formats;
}

// セレクトに出す名前。formats は formatsFor の結果。FLAC は、FLAC の音源をそのまま切るとき (FLAC が先頭) だけ
// 「無劣化」と書く (ほかの音源からはエンコードする)
export const formatLabel = (format: OutFormat, formats: OutFormat[]) => (format === 'flac' && formats[0] !== 'flac' ? 'FLAC' : OUT_FORMATS[format].label);

// 同じ中身で拡張子だけが違う形式か。opus は音源が Ogg Opus か。Ogg Opus は .opus と .ogg のどちらの名前でも書ける
// (Ogg Vorbis は .ogg だけ)
export const sameContent = (a: OutFormat, b: OutFormat, opus: boolean) => a === b || (opus && isOgg(a) && isOgg(b));
export const isOgg = (f: OutFormat) => f === 'opus' || f === 'ogg';

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
