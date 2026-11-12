// 音源の形式と元のサンプルレートを、kiln の detect でファイルのヘッダーから調べる。音源を開くとき (main.ts の decode) の
// レートと、クロップの準備 (cropRender.ts の inspect) の形式に使う
import type { Detected, Format, Kiln } from '../kiln/wasm/kiln';
import { extFormat } from './cropFormat';
import { loadKiln } from './kilnLoader';

// AudioContext と OfflineAudioContext が受け付けるレートの範囲。外れた値は、元のレートが分からないものとして扱う
const MIN_RATE = 3000;
const MAX_RATE = 768000;

// kiln に渡す、ファイルの先頭の大きさ。kiln は渡した分をまるごと wasm のメモリに写し、wasm のメモリは増えると減らないので、
// 大きな音源 (WAV など) をそのまま渡さない。レートはヘッダーにあり、たいていはこの中に入っている
const HEAD_BYTES = 64 * 1024;

// 先頭に続く ID3v2 タグの長さの合計。タグがなければ 0。mp3 (と、まれに FLAC) の先頭にあり、画像が入っていると HEAD_BYTES より
// 大きい。ヘッダーはタグの後ろにあるので、その分も kiln に渡す。kiln (id3.zig の skipTags) は続くタグをすべて飛ばすので、
// ここでもすべて数える (1 つ目だけを数えると、2 つ目のタグの途中で切れて、kiln がヘッダーに届かない)
function id3v2Size(d: Uint8Array): number {
  let pos = 0;
  while (d.length - pos >= 10 && d[pos] === 0x49 && d[pos + 1] === 0x44 && d[pos + 2] === 0x33) {   // "ID3"
    const footer = d[pos + 3] === 4 && (d[pos + 5] & 0x10) !== 0 ? 10 : 0;
    // 長さは、7 ビットずつの 4 バイト
    pos += 10 + footer + (((d[pos + 6] & 0x7f) << 21) | ((d[pos + 7] & 0x7f) << 14) | ((d[pos + 8] & 0x7f) << 7) | (d[pos + 9] & 0x7f));
  }
  return pos;
}

// kiln に渡す、ファイルの先頭 (ID3v2 タグがあれば、その後ろの HEAD_BYTES まで)
const headOf = (bytes: Uint8Array<ArrayBuffer>) => bytes.subarray(0, id3v2Size(bytes) + HEAD_BYTES);

// mp3 とみなすのは、拡張子が .mp3 のものだけ。mp3 は印がなくフレームの並びで判定するので、ほかの形式を読み違えないようにする。
// 逆に、拡張子が .mp3 なのに mp3 と判定できなかった音源は、クロップの準備 (cropRender.ts の probeSource) が mp3 の解析を試す
export const hasMp3Ext = (fileName: string) => extFormat(fileName) === 'mp3';
const accept = (d: Detected | null, fileName: string) => (d?.format === 'mp3' && !hasMp3Ext(fileName) ? null : d);

// 音源の形式。判定できなければ null。形式はファイルの先頭だけで決まる (mp3 は、最初のフレームが先頭の HEAD_BYTES の中に
// あるものだけ)
export function sourceFormat(k: Kiln, fileName: string, bytes: Uint8Array<ArrayBuffer>): Format | null {
  return accept(k.detect(headOf(bytes)), fileName)?.format ?? null;
}

// 音源の元のサンプルレート (デコード結果のレート。Opus は常に 48kHz)。分からなければ null で、呼ぶ側で出力の機器のレートを使う。
// kiln.detect はヘッダーだけを読むので、kiln が中身を扱えない音源 (MPEG-2 の mp3、μ-law の WAV、連結した Ogg など) でも分かる。
// 分からないのは、.aac の ADTS (ヘッダーから HE-AAC かどうかが分からない)、SBR があるか分からない m4a (レートが実際の
// 半分のことがある)、形式を判定できない音源
export async function sourceRate(fileName: string, bytes: Uint8Array<ArrayBuffer>): Promise<number | null> {
  const k = await loadKiln();
  const head = headOf(bytes);
  let d = k.detect(head);
  // ヘッダーが先頭に入っていないことがあるのは、WAV (fmt チャンクが後ろ) と m4a (moov が後ろ。ffmpeg の既定) だけ。
  // そのときだけ全体を渡し直す。形式を判定できない音源は渡し直さない (全体から mp3 のフレームを探すと、偶然それらしい
  // 並びを拾うことがある)。SBR があるか分からない m4a は、全体を渡しても分からないが、moov が後ろの m4a と見分けられない
  if (d !== null && d.sampleRate === null && (d.format === 'wav' || d.format === 'm4a') && head.length < bytes.length) d = k.detect(bytes);
  const rate = accept(d, fileName)?.sampleRate ?? null;
  return rate !== null && rate >= MIN_RATE && rate <= MAX_RATE ? rate : null;
}
