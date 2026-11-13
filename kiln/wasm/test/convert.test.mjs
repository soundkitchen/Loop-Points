// SPDX-License-Identifier: MIT
// mp3 / wav / flac の切り出し・デコード・書き出しと、ogg(Opus / Vorbis)、m4a(AAC)、aac(ADTS。m4a に入れ替える)の切り出しの実行時テスト。wasm/kiln.ts、zig build でできた zig-out/kiln.wasm、testdata/ を読む。
// kiln.ts の Exports(wasm の export 関数の型)は wasm/main.zig を手で写したものなので、引数の数や並びがずれると
// wasm は足りない引数を 0 として黙って動く。各経路を実際に呼び、結果を probe で確かめて、そのずれに気づけるようにする。
// Loop Points のリポジトリ直下の `npm run kiln:test` で動く
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { load } = await import(path.join(root, 'wasm/kiln.ts'));
const kiln = await load(await readFile(path.join(root, 'zig-out/kiln.wasm')));
const data = (name) => readFile(path.join(root, 'testdata', name));

// 2 チャンネル、1000 サンプルの PCM と、それを持つ AudioBuffer の代わり
const pcm = [new Float32Array(1000).map((_, i) => Math.sin(i / 10) * 0.5), new Float32Array(1000).map((_, i) => Math.cos(i / 7) * 0.5)];
const buffer = { numberOfChannels: 2, sampleRate: 44100, getChannelData: (i) => pcm[i] };

test('mp3.trim / toWav / toFlac / decode', async () => {
  const mp3 = await data('cbr128-lame.mp3');   // 44.1kHz、2 チャンネル、88200 サンプル
  const t = kiln.mp3.trim(mp3, { startSample: 4410, endSample: 44100 });
  assert.deepEqual([t.startSample, t.endSample], [4410, 44100]);
  assert.equal(kiln.mp3.probe(t.data).samples, 44100 - 4410);

  const w = kiln.mp3.toWav(mp3, { start: 0.5, end: 1, format: 'i24' });
  assert.deepEqual(kiln.wav.probe(w.data), { sampleRate: 44100, channels: 2, format: 'i24', samples: 22050, duration: 0.5 });
  assert.equal(w.invalidFrames, 0);

  const f = kiln.mp3.toFlac(mp3, { endSample: 1000, compression: 0 });   // bitsPerSample を省くと 16
  assert.equal(kiln.flac.probe(f.data).bitsPerSample, 16);
  assert.equal(kiln.flac.probe(f.data).samples, 1000);
  assert.equal(kiln.flac.probe(kiln.mp3.toFlac(mp3, { endSample: 1000, bitsPerSample: 24 }).data).bitsPerSample, 24);

  const d = kiln.mp3.decode(mp3, { startSample: 100, endSample: 300 });
  assert.equal(d.channels.length, 2);
  assert.equal(d.channels[0].length, 200);
  assert.equal(d.sampleRate, 44100);
});

test('wav.trim / encode / toFlac', async () => {
  const wav = await data('s24-stereo.wav');   // 48kHz、2 チャンネル、24bit、12000 サンプル
  const t = kiln.wav.trim(wav, { startSample: 1000, endSample: 3000 });
  assert.deepEqual(kiln.wav.probe(t.data), { sampleRate: 48000, channels: 2, format: 'i24', samples: 2000, duration: 2000 / 48000 });

  assert.deepEqual(kiln.wav.probe(kiln.wav.encode(buffer)), { sampleRate: 44100, channels: 2, format: 'i16', samples: 1000, duration: 1000 / 44100 });
  assert.equal(kiln.wav.probe(kiln.wav.encode(pcm, { sampleRate: 48000, format: 'f32', dither: 'none' })).format, 'f32');

  // bitsPerSample を省くと、整数の WAV は元のビット深度のまま
  const keep = kiln.flac.probe(kiln.wav.toFlac(wav, { startSample: 0, endSample: 6000 }).data);
  assert.deepEqual([keep.bitsPerSample, keep.samples, keep.sampleRate], [24, 6000, 48000]);
  assert.equal(kiln.flac.probe(kiln.wav.toFlac(wav, { bitsPerSample: 16, compression: 8 }).data).bitsPerSample, 16);
});

test('flac.trim / toWav / decode / encode', async () => {
  const flac = await data('s24-stereo.flac');   // 48kHz、2 チャンネル、24bit、12000 サンプル
  const t = kiln.flac.trim(flac, { start: 0.05, end: 0.2 });
  assert.deepEqual([t.startSample, t.endSample, t.invalidFrames], [2400, 9600, 0]);
  assert.equal(kiln.flac.probe(t.data).samples, 7200);

  // format を省くとビット深度を保つ形式
  assert.equal(kiln.wav.probe(kiln.flac.toWav(flac, { endSample: 100 }).data).format, 'i24');
  assert.equal(kiln.wav.probe(kiln.flac.toWav(flac, { endSample: 100, format: 'i16' }).data).format, 'i16');

  const d = kiln.flac.decode(flac, { startSample: 10, endSample: 20 });
  assert.deepEqual([d.channels.length, d.channels[1].length, d.sampleRate], [2, 10, 48000]);

  const e = kiln.flac.probe(kiln.flac.encode(buffer, { bitsPerSample: 20 }));
  assert.deepEqual([e.sampleRate, e.channels, e.bitsPerSample, e.samples], [44100, 2, 20, 1000]);
  assert.equal(kiln.flac.probe(kiln.flac.encode(pcm, { sampleRate: 8000 })).bitsPerSample, 16);
});

test('ogg.trim(Opus)', async () => {
  const opus = await data('opus-stereo.opus');   // 48kHz(Opus のデコード結果)、24000 サンプル
  const t = kiln.ogg.trim(opus, { startSample: 5000, endSample: 15000 });
  assert.deepEqual([t.startSample, t.endSample], [5000, 15000]);
  const p = kiln.ogg.probe(t.data);
  assert.deepEqual([p.codec, p.samples, p.sampleRate, p.channels, p.invalidPages], ['opus', 10000, 48000, 2, 0]);
  // 秒でも指定できる。末尾は長さで切り詰める
  const s = kiln.ogg.trim(opus, { start: 0.25, end: 10 });
  assert.deepEqual([s.startSample, s.endSample, kiln.ogg.probe(s.data).samples], [12000, 24000, 12000]);
});

test('ogg.trim(Vorbis)', async () => {
  const vorbis = await data('vorbis-stereo.ogg');   // 44.1kHz、22050 サンプル
  const t = kiln.ogg.trim(vorbis, { startSample: 5000, endSample: 15000 });
  // 先頭はパケットの区切りに寄せる(指定以下)。末尾は区間どおり
  assert.ok(t.startSample <= 5000 && t.startSample > 5000 - 1024, `${t.startSample}`);
  assert.equal(t.endSample, 15000);
  const p = kiln.ogg.probe(t.data);
  assert.deepEqual([p.codec, p.samples, p.sampleRate, p.channels, p.invalidPages], ['vorbis', 15000 - t.startSample, 44100, 2, 0]);
  // 全体
  const all = kiln.ogg.trim(vorbis);
  assert.deepEqual([all.startSample, all.endSample, kiln.ogg.probe(all.data).samples], [0, 22050, 22050]);
});

test('m4a.trim', async () => {
  const he = await data('aac-he-afconvert.m4a');   // HE-AAC、出力は 44.1kHz、22050 サンプル。タイムスケールは中心の 22.05kHz
  const t = kiln.m4a.trim(he, { startSample: 5000, endSample: 15000 });
  assert.deepEqual([t.startSample, t.endSample], [5000, 15000]);
  const p = kiln.m4a.probe(t.data);
  assert.deepEqual([p.codec, p.profile, p.samples, p.sampleRate, p.channels, p.trimmable], ['aac', 'he', 10000, 44100, 2, true]);
  // HE-AAC はタイムスケールの単位(2 サンプル)に寄せる。先頭は切り捨て、終わりは切り上げ
  const odd = kiln.m4a.trim(he, { startSample: 5001, endSample: 15001 });
  assert.deepEqual([odd.startSample, odd.endSample, kiln.m4a.probe(odd.data).samples], [5000, 15002, 10002]);
  // AAC-LC はサンプル単位。全体
  const lc = await data('aac-lc-ffmpeg.m4a');
  const one = kiln.m4a.trim(lc, { startSample: 5001, endSample: 5002 });
  assert.deepEqual([one.startSample, one.endSample, kiln.m4a.probe(one.data).samples], [5001, 5002, 1]);
  const all = kiln.m4a.trim(lc);
  assert.deepEqual([all.startSample, all.endSample, kiln.m4a.probe(all.data).samples], [0, 22050, 22050]);
  // ALAC は切り出さない
  const alac = await data('alac-afconvert.m4a');
  assert.throws(() => kiln.m4a.trim(alac), { code: 'UnsupportedFormat' });
});

test('aac.trim', async () => {
  const lc = await data('lc-ffmpeg.aac');   // AAC-LC、44.1kHz、23 フレーム(23552 サンプル)
  const t = kiln.aac.trim(lc, { startSample: 5001, endSample: 9000, sbr: false });
  assert.deepEqual([t.startSample, t.endSample], [5001, 9000]);
  const p = kiln.m4a.probe(t.data);
  assert.deepEqual([p.codec, p.profile, p.samples, p.sampleRate, p.channels, p.trimmable], ['aac', 'lc', 3999, 44100, 2, true]);
  // 秒の区間も数えられる
  const sec = kiln.aac.trim(lc, { start: 0.1, end: 0.2, sbr: false });
  assert.deepEqual([sec.startSample, sec.endSample], [4410, 8820]);
  // HE-AAC は出力のレート(ヘッダの 2 倍)で数え、2 サンプル単位に寄せる
  const he = await data('he-afconvert.aac');   // ヘッダは 22.05kHz の AAC-LC に見える
  const h = kiln.aac.trim(he, { startSample: 5001, endSample: 15001, sbr: true });
  assert.deepEqual([h.startSample, h.endSample, h.end], [5000, 15002, 15002 / 44100]);
  const hp = kiln.m4a.probe(h.data);
  assert.deepEqual([hp.profile, hp.samples, hp.sampleRate], ['he', 10002, 44100]);
  const hs = kiln.aac.trim(he, { start: 0.1, end: 0.2, sbr: true });
  assert.deepEqual([hs.startSample, hs.endSample], [4410, 8820]);
  assert.throws(() => kiln.aac.trim(lc, { startSample: 100, endSample: 100, sbr: false }), { code: 'EmptyRange' });
});
