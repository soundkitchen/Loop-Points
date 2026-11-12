// SPDX-License-Identifier: MIT
// 誤った使い方が型エラーになることの検査。実行はせず、Loop Points の tsc(npm run build と npm run kiln:test)で確かめる。
// kiln.ts の型を緩めると @ts-expect-error が不要になって tsc が失敗する。意図して緩めるときは、ここも直す
import { load, type Kiln, type KilnErrorCode, type AacInfo } from '../kiln';

export function misuse(k: Kiln, bytes: Uint8Array) {
  // @ts-expect-error wasm のバイト列は省けない
  load();
  // @ts-expect-error URL からは読まない(バイト列だけ)
  load(new URL('https://example.com/kiln.wasm'));
  // @ts-expect-error start と startSample は同時に指定できない
  k.mp3.trim(bytes, { start: 1, startSample: 2 });
  // @ts-expect-error end と endSample は同時に指定できない
  k.wav.trim(bytes, { end: 1, endSample: 2 });
  // @ts-expect-error 未知のサンプル形式
  k.mp3.toWav(bytes, { format: 'i8' });
  // @ts-expect-error 未知のディザ
  k.flac.toWav(bytes, { dither: 'rectangular' });
  // @ts-expect-error Float32Array[] のときは sampleRate が要る
  k.wav.encode([new Float32Array(4)]);
  // @ts-expect-error Float32Array[] のときは sampleRate が要る
  k.flac.encode([new Float32Array(4)]);
  // @ts-expect-error flac.trim に書き出しの指定はない
  k.flac.trim(bytes, { compression: 5 });
  // @ts-expect-error detect の結果は null のことがある
  k.detect(bytes).sampleRate;
  // @ts-expect-error detect の sampleRate は null のことがある
  const rate: number = k.detect(bytes)!.sampleRate;
  // @ts-expect-error code は決まった名前だけ
  const code: KilnErrorCode = 'Oops';
  // @ts-expect-error aac の profile に HE-AAC はない(ADTS のヘッダに書けない)
  const profile: AacInfo['profile'] = 'he';
  return [code, profile, rate];
}
