// 音源の元のサンプルレートを kiln で調べる。音源を開くとき (main.ts の decode) に使う
import { extFormat } from './cropFormat';
import { loadKiln } from './kilnLoader';

// AudioContext と OfflineAudioContext が受け付けるレートの範囲。外れた値は、元のレートが分からないものとして扱う
const MIN_RATE = 3000;
const MAX_RATE = 768000;

// kiln に渡す、ファイルの先頭の大きさ。kiln は渡した分をまるごと wasm のメモリに写し、wasm のメモリは増えると減らないので、
// 大きな音源 (WAV など) をそのまま渡さない。レートはヘッダーにあり、たいていはこの中に入っている
const HEAD_BYTES = 64 * 1024;

// 先頭の ID3v2 タグの長さ。タグがなければ 0。mp3 (と、まれに FLAC) の先頭にあり、画像が入っていると HEAD_BYTES より大きい。
// ヘッダーはタグの後ろにあるので、その分も kiln に渡す
function id3v2Size(d: Uint8Array): number {
  if (d.length < 10 || d[0] !== 0x49 || d[1] !== 0x44 || d[2] !== 0x33) return 0;   // "ID3"
  const footer = d[3] === 4 && (d[5] & 0x10) !== 0 ? 10 : 0;
  // 長さは、7 ビットずつの 4 バイト
  return 10 + footer + (((d[6] & 0x7f) << 21) | ((d[7] & 0x7f) << 14) | ((d[8] & 0x7f) << 7) | (d[9] & 0x7f));
}

// 音源の元のサンプルレート (デコード結果のレート。Opus は常に 48kHz)。分からなければ null で、呼ぶ側で出力の機器のレートを使う。
// kiln.detect はヘッダーだけを読むので、kiln が中身を扱えない音源 (MPEG-2 の mp3、μ-law の WAV、連結した Ogg など) でも分かる。
// 分からないのは、.aac の ADTS (ヘッダーから HE-AAC かどうかが分からない)、SBR があるか分からない m4a (レートが実際の
// 半分のことがある)、形式を判定できない音源
export async function sourceRate(fileName: string, bytes: Uint8Array<ArrayBuffer>): Promise<number | null> {
  const k = await loadKiln();
  const head = bytes.subarray(0, id3v2Size(bytes) + HEAD_BYTES);
  let d = k.detect(head);
  // ヘッダーが先頭に入っていないことがあるのは、WAV (fmt チャンクが後ろ) と m4a (moov が後ろ。ffmpeg の既定) だけ。
  // そのときだけ全体を渡し直す。形式を判定できない音源は渡し直さない (全体から mp3 のフレームを探すと、偶然それらしい
  // 並びを拾うことがある)。SBR があるか分からない m4a は、全体を渡しても分からないが、moov が後ろの m4a と見分けられない
  if (d !== null && d.sampleRate === null && (d.format === 'wav' || d.format === 'm4a') && head.length < bytes.length) d = k.detect(bytes);
  // mp3 とみなすのは、クロップの準備 (cropRender.ts の probeSource) と同じく、拡張子が .mp3 のものだけ。
  // mp3 は印がなくフレームの並びで判定するので、ほかの形式を読み違えないようにする
  if (d?.format === 'mp3' && extFormat(fileName) !== 'mp3') return null;
  const rate = d?.sampleRate ?? null;
  return rate !== null && rate >= MIN_RATE && rate <= MAX_RATE ? rate : null;
}
