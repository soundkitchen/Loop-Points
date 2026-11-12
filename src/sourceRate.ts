// 音源の元のサンプルレートを kiln で調べる。音源を開くとき (main.ts の decode) に使う
import { loadKiln } from './kilnLoader';

// AudioContext と OfflineAudioContext が受け付けるレートの範囲。外れた値は、元のレートが分からないものとして扱う
const MIN_RATE = 3000;
const MAX_RATE = 768000;

// kiln に渡す、ファイルの先頭の大きさ。kiln は渡した分をまるごと wasm のメモリに写し、wasm のメモリは増えると減らないので、
// 大きな音源 (WAV など) をそのまま渡さない。レートはヘッダーにあり、たいていはこの中に入っている
const HEAD_BYTES = 64 * 1024;

// 音源の元のサンプルレート (デコード結果のレート。Opus は常に 48kHz)。分からなければ null で、呼ぶ側で出力の機器のレートを使う。
// kiln.detect はヘッダーだけを読むので、kiln が中身を扱えない音源 (MPEG-2 の mp3、μ-law の WAV、連結した Ogg など) でも分かる。
// 分からないのは、.aac の ADTS (ヘッダーから HE-AAC かどうかが分からない)、SBR があるか分からない m4a (レートが実際の
// 半分のことがある)、形式を判定できない音源
export async function sourceRate(bytes: Uint8Array<ArrayBuffer>): Promise<number | null> {
  const k = await loadKiln();
  // 先頭で読めなければ、全体を渡し直す (ID3v2 タグの大きい mp3、moov が後ろにある m4a など)
  const rate = k.detect(bytes.subarray(0, HEAD_BYTES))?.sampleRate
    ?? (bytes.length > HEAD_BYTES ? k.detect(bytes)?.sampleRate : null) ?? null;
  return rate !== null && rate >= MIN_RATE && rate <= MAX_RATE ? rate : null;
}
