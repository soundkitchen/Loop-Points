// 音源の一部を指定の形式のファイルにする。エンコーダが大きいので、main からは書き出すときに読み込む
import { OUT_FORMATS, type OutFormat } from './cropFormat';
import { encodeMp3, encodeOgg } from './encoders';
import { addInfoTag } from './mp3Tag';
import { sampleRateOf } from './sampleRate';
import { encodeWav16, parseWav, sliceWav } from './wav';

const MP3_RATES = [32000, 44100, 48000];   // Info タグを書ける MPEG1 のレート

// mp3 にできないレートは、近い系列のレートに変換する
const mp3Rate = (rate: number) => (MP3_RATES.includes(rate) ? rate : rate % 11025 === 0 ? 44100 : 48000);

// start 以上 end 未満 (decoded のサンプル) を書き出す。デコードは AudioContext のレートに変換されているので、
// 元のレートが分かるときはそのレートで元のファイルをデコードし直し、音を変換しないで済むようにする
export async function renderCrop(source: File, decoded: AudioBuffer, start: number, end: number, format: OutFormat): Promise<Blob> {
  const bytes = await source.arrayBuffer();
  const toRate = (s: number, rate: number) => Math.round((s / decoded.sampleRate) * rate);

  if (format === 'wav') {
    const wav = parseWav(bytes);
    if (wav) return sliceWav(source, wav, toRate(start, wav.sampleRate), toRate(end, wav.sampleRate));
  }

  const original = sampleRateOf(bytes) ?? decoded.sampleRate;
  const rate = format === 'mp3' ? mp3Rate(original) : original;
  const audio = rate === decoded.sampleRate ? decoded : await new OfflineAudioContext(decoded.numberOfChannels, 1, rate).decodeAudioData(bytes);
  const a = toRate(start, rate), z = Math.min(toRate(end, rate), audio.length);
  const channels = Array.from({ length: audio.numberOfChannels }, (_, c) => audio.getChannelData(c).subarray(a, z));

  if (format === 'wav') return encodeWav16(channels, rate);
  const out = format === 'mp3' ? addInfoTag(await encodeMp3(channels, rate), z - a) : await encodeOgg(channels, rate);
  return new Blob([out as Uint8Array<ArrayBuffer>], { type: OUT_FORMATS[format].mime });
}
