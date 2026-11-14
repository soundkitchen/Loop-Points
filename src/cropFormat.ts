// クロップの書き出し形式。mp3、FLAC、Ogg (Opus、Vorbis)、m4a (AAC) の音源は、再エンコードせずに元の形式で切り出せる。
// aac (ADTS) の音源は、再エンコードせずに m4a に入れ替えて切り出せる (ADTS には前後の余分を捨てる指定を書けないため)。
// WAV と FLAC はどの音源からも書き出せる (FLAC の音源以外は、デコードして FLAC にエンコードする)。Ogg Vorbis にも、
// デコードしてエンコードすれば書き出せる (劣化する)。
// opus は Ogg Opus。ogg は Ogg Opus か Ogg Vorbis (元の音源と同じ中身)。Ogg Opus は元の音源の拡張子に合わせる。
// vorbis は、デコードして Ogg Vorbis にエンコードしたもの (劣化する)。ogg と同じく拡張子は .ogg
export type OutFormat = 'wav' | 'mp3' | 'flac' | 'opus' | 'ogg' | 'm4a' | 'vorbis';

export const OUT_FORMATS: Record<OutFormat, { label: string; description: string; mime: string; ext: string }> = {
  mp3: { label: 'mp3 (無劣化)', description: 'MP3', mime: 'audio/mpeg', ext: '.mp3' },
  flac: { label: 'FLAC (無劣化)', description: 'FLAC', mime: 'audio/flac', ext: '.flac' },
  opus: { label: 'Opus (無劣化)', description: 'Opus', mime: 'audio/ogg', ext: '.opus' },
  ogg: { label: 'Ogg (無劣化)', description: 'Ogg', mime: 'audio/ogg', ext: '.ogg' },
  m4a: { label: 'm4a (無劣化)', description: 'm4a', mime: 'audio/mp4', ext: '.m4a' },
  wav: { label: 'WAV', description: 'WAV', mime: 'audio/wav', ext: '.wav' },
  vorbis: { label: 'Ogg Vorbis', description: 'Ogg Vorbis', mime: 'audio/ogg', ext: '.ogg' },
};

const extOf = (fileName: string) => /\.[^.]+$/.exec(fileName)?.[0].toLowerCase();

// 拡張子から、音源の形式を決める。どれでもなければ null。.ogg は ogg (エンコードした vorbis ではなく、元の Ogg)
export function extFormat(fileName: string): OutFormat | null {
  const ext = extOf(fileName);
  return (Object.keys(OUT_FORMATS) as OutFormat[]).find((f) => OUT_FORMATS[f].ext === ext) ?? null;
}

// kiln の FLAC のエンコーダーが書けるチャンネル数の上限 (FLAC の仕様の上限)
const FLAC_MAX_CHANNELS = 8;
// Ogg Vorbis にエンコードできる上限。チャンネル数は kiln の上限 (Vorbis の仕様が並びを決めているのは 8 までで、
// Chromium もそれより多いものはデコードできない)。サンプルレートは、kiln が使う libvorbis の上限
const VORBIS_MAX_CHANNELS = 8;
const VORBIS_MAX_RATE = 200_000;

// 音源から書き出せる形式。先頭が初期値。native は元の形式のまま切り出せる形式 (mp3、FLAC、Ogg、m4a。aac は m4a) で、
// その形式、WAV、FLAC の順に並べる (FLAC の音源は FLAC と WAV)。それ以外 (null や WAV) は WAV と FLAC。
// 最後に、エンコードする Ogg Vorbis を足す。ただし、9 チャンネル以上の音源は FLAC にも Ogg Vorbis にもできないので除き、
// サンプルレートが 200kHz を超える音源と、Vorbis のまま切り出せる音源 (vorbisNative。同じ .ogg が 2 つ並ぶうえ、
// エンコードし直すと劣化する) にも Ogg Vorbis は出さない。
// kiln が中身を調べる前は拡張子から、調べた後は kiln の結果から native を決める (cropRender.ts の inspect)
export function formatsFor(native: OutFormat | null, source: { channels: number; sampleRate: number; vorbisNative?: boolean }): OutFormat[] {
  const formats: OutFormat[] = native === 'flac' ? ['flac', 'wav'] : native && native !== 'wav' ? [native, 'wav', 'flac'] : ['wav', 'flac'];
  if (!source.vorbisNative && source.sampleRate <= VORBIS_MAX_RATE) formats.push('vorbis');
  return formats.filter((f) => !(f === 'flac' && source.channels > FLAC_MAX_CHANNELS) && !(f === 'vorbis' && source.channels > VORBIS_MAX_CHANNELS));
}

// セレクトに出す名前。formats は formatsFor の結果。FLAC は、FLAC の音源をそのまま切るとき (FLAC が先頭) だけ
// 「無劣化」と書く (ほかの音源からはエンコードする)
export const formatLabel = (format: OutFormat, formats: OutFormat[]) => (format === 'flac' && formats[0] !== 'flac' ? 'FLAC' : OUT_FORMATS[format].label);

// 元の Ogg のまま切り出す形式か (エンコードする vorbis は含めない)
export const isOgg = (f: OutFormat) => f === 'opus' || f === 'ogg';

// 名前の拡張子が、その形式のものか。opus は音源が Ogg Opus か。Ogg Opus をそのまま切り出したものは、.opus と .ogg の
// どちらの名前でも書ける (Ogg Vorbis は .ogg だけ)
export function extMatches(fileName: string, format: OutFormat, opus: boolean): boolean {
  const ext = extOf(fileName);
  return OUT_FORMATS[format].ext === ext || (opus && isOgg(format) && (ext === '.opus' || ext === '.ogg'));
}

export function croppedName(fileName: string, format: OutFormat): string {
  return `${fileName.replace(/\.[^.]+$/, '')}-cropped${OUT_FORMATS[format].ext}`;
}
