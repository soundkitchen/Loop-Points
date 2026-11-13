// SPDX-License-Identifier: MIT
// detect と、ogg / m4a / aac の probe の実行時テスト。wasm/kiln.ts、zig build でできた zig-out/kiln.wasm、testdata/ を読む。
// Loop Points のリポジトリ直下の `npm run kiln:test` で動く(kiln/ で `zig build && node --test 'wasm/test/*.test.mjs'` でもよい)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { load, KilnError } = await import(path.join(root, 'wasm/kiln.ts'));
const kiln = await load(await readFile(path.join(root, 'zig-out/kiln.wasm')));
const data = (name) => readFile(path.join(root, 'testdata', name));

test('detect', async () => {
  const cases = {
    'cbr128-lame.mp3': { format: 'mp3', sampleRate: 44100 },
    'mono48k-notag.mp3': { format: 'mp3', sampleRate: 48000 },
    's24-stereo.wav': { format: 'wav', sampleRate: 48000 },
    's20-mono.flac': { format: 'flac', sampleRate: 96000 },
    'opus-stereo.opus': { format: 'ogg', sampleRate: 48000 },
    'vorbis-mono22k.ogg': { format: 'ogg', sampleRate: 22050 },
    'aac-lc-ffmpeg.m4a': { format: 'm4a', sampleRate: 44100 },
    'aac-he-afconvert.m4a': { format: 'm4a', sampleRate: 44100 },
    // aac(ADTS)は、ヘッダーから HE-AAC かどうかが分からないので、レートは読まない
    'lc-ffmpeg.aac': { format: 'aac', sampleRate: null },
    'he-afconvert.aac': { format: 'aac', sampleRate: null },
  };
  for (const [name, want] of Object.entries(cases)) assert.deepEqual(kiln.detect(await data(name)), want, name);

  // 形式が分からなければ null(投げない)
  assert.equal(kiln.detect(new Uint8Array(0)), null);
  assert.equal(kiln.detect(new TextEncoder().encode('not audio at all')), null);

  // ファイルの先頭の一部でも読める。ヘッダーが入っていないと、レートは null
  const head = async (name, n) => (await data(name)).subarray(0, n);
  assert.deepEqual(kiln.detect(await head('s24-stereo.wav', 64)), { format: 'wav', sampleRate: 48000 });
  assert.deepEqual(kiln.detect(await head('s20-mono.flac', 64)), { format: 'flac', sampleRate: 96000 });
  assert.deepEqual(kiln.detect(await head('vorbis-mono22k.ogg', 128)), { format: 'ogg', sampleRate: 22050 });
  assert.deepEqual(kiln.detect(await head('cbr128-lame.mp3', 2048)), { format: 'mp3', sampleRate: 44100 });
  // ffmpeg の m4a は moov が後ろにある
  assert.deepEqual(kiln.detect(await head('aac-lc-ffmpeg.m4a', 4096)), { format: 'm4a', sampleRate: null });
  assert.deepEqual(kiln.detect(await head('aac-lc-afconvert.m4a', 4088)), { format: 'm4a', sampleRate: 44100 });

  // kiln が扱えない MPEG-2 Layer III(22.05kHz)も、形式とヘッダーのレートを返す
  const mpeg2 = new Uint8Array(208 * 2);
  for (const at of [0, 208]) mpeg2.set([0xff, 0xf3, 0x80, 0xc4], at);
  assert.deepEqual(kiln.detect(mpeg2), { format: 'mp3', sampleRate: 22050 });
  assert.throws(() => kiln.mp3.probe(mpeg2), (e) => e instanceof KilnError && e.code === 'UnsupportedFormat');
});

test('ogg.probe', async () => {
  assert.deepEqual(kiln.ogg.probe(await data('opus-stereo.opus')), {
    codec: 'opus',
    sampleRate: 48000,
    inputSampleRate: 44100,
    channels: 2,
    samples: 24000,
    duration: 0.5,
    preSkip: 312,
    invalidPages: 0,
    trimmable: true,
  });
  const v = kiln.ogg.probe(await data('vorbis-mono22k.ogg'));
  assert.equal(v.codec, 'vorbis');
  assert.equal(v.inputSampleRate, null);
  assert.equal(v.sampleRate, 22050);
  assert.equal(v.samples, 11025);
  assert.equal(v.trimmable, true);
});

test('m4a.probe', async () => {
  const lc = kiln.m4a.probe(await data('aac-lc-ffmpeg.m4a'));
  assert.equal(lc.codec, 'aac');
  assert.equal(lc.profile, 'lc');
  assert.equal(lc.sbr, false);
  assert.equal(lc.samples, 22050);
  assert.equal(lc.encoderDelay, 1024);
  assert.equal(lc.bitsPerSample, null);
  assert.deepEqual([...lc.audioSpecificConfig], [0x12, 0x10, 0x56, 0xe5, 0x00]);
  assert.equal(lc.trimmable, true);
  const v2 = kiln.m4a.probe(await data('aac-hev2-afconvert.m4a'));
  assert.equal(v2.profile, 'hev2');
  assert.equal(v2.objectType, 2);
  assert.equal(v2.sbr, true);
  assert.equal(v2.ps, true);
  assert.equal(v2.sampleRate, 44100);
  assert.equal(v2.channels, 2);
  const alac = kiln.m4a.probe(await data('alac-afconvert.m4a'));
  assert.equal(alac.codec, 'alac');
  assert.equal(alac.profile, null);
  assert.equal(alac.bitsPerSample, 16);
  assert.equal(alac.audioSpecificConfig.length, 0);
  assert.equal(alac.trimmable, false);
});

test('aac.probe', async () => {
  assert.deepEqual(kiln.aac.probe(await data('he-afconvert.aac')), {
    profile: 'lc',
    mpegVersion: 2,
    sbr: null,
    sampleRate: 22050,
    channels: 2,
    frames: 14,
    samples: 14336,
    duration: 14336 / 22050,
    trimmable: true,
    sbrTrimmable: true,
  });
});

test('形式が違うと KilnError', async () => {
  const mp3 = await data('cbr128-lame.mp3');
  for (const [fn, code] of [[kiln.ogg.probe, 'NotOgg'], [kiln.m4a.probe, 'NotM4a'], [kiln.aac.probe, 'NotAac']]) {
    assert.throws(() => fn(mp3), (e) => e instanceof KilnError && e.code === code);
  }
  assert.throws(() => kiln.ogg.probe(new TextEncoder().encode('OggS')), (e) => e.code === 'InvalidOgg');
});
