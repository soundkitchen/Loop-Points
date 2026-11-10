// SPDX-License-Identifier: MIT
// ogg / m4a / aac の probe の実行時テスト。wasm/kiln.js、zig build でできた zig-out/wasm/kiln.wasm、testdata/ を読む。
// Loop Points のリポジトリ直下の `npm run kiln:test` で動く(kiln/ で `zig build && node --test 'wasm/test/*.test.mjs'` でもよい)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { load, KilnError } = await import(path.join(root, 'wasm/kiln.js'));
const kiln = await load(await readFile(path.join(root, 'zig-out/wasm/kiln.wasm')));
const data = (name) => readFile(path.join(root, 'testdata', name));

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
  });
  const v = kiln.ogg.probe(await data('vorbis-mono22k.ogg'));
  assert.equal(v.codec, 'vorbis');
  assert.equal(v.inputSampleRate, null);
  assert.equal(v.sampleRate, 22050);
  assert.equal(v.samples, 11025);
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
  });
});

test('形式が違うと KilnError', async () => {
  const mp3 = await data('cbr128-lame.mp3');
  for (const [fn, code] of [[kiln.ogg.probe, 'NotOgg'], [kiln.m4a.probe, 'NotM4a'], [kiln.aac.probe, 'NotAac']]) {
    assert.throws(() => fn(mp3), (e) => e instanceof KilnError && e.code === code);
  }
  assert.throws(() => kiln.ogg.probe(new TextEncoder().encode('OggS')), (e) => e.code === 'InvalidOgg');
});
