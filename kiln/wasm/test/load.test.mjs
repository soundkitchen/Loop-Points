// SPDX-License-Identifier: MIT
// kiln.js の load の実行時テスト。wasm/kiln.js と、zig build でできた zig-out/wasm/kiln.wasm を読む。
// Loop Points のリポジトリ直下の `npm run kiln:test` で動く(kiln/ で `zig build && node --test 'wasm/test/*.test.mjs'` でもよい)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const { load } = await import(path.join(root, 'wasm/kiln.js'));
const wasm = await readFile(path.join(root, 'zig-out/wasm/kiln.wasm'));
const flac = await readFile(path.join(root, 'testdata/s16-stereo.flac'));

test('バイト列でない値(URL を含む)は、TypeError で reject する', async () => {
  for (const source of [undefined, null, 1, {}, 'kiln.wasm', new URL('http://127.0.0.1/kiln.wasm'), new Blob([wasm]), new Response(wasm), Promise.resolve(wasm)]) {
    const p = load(source);
    assert.ok(p instanceof Promise, 'load は投げずに Promise を返す');
    await assert.rejects(p, TypeError);
  }
});

test('バイト列で読み込める(Buffer、ArrayBuffer、先頭がずれた TypedArray)', async () => {
  const shifted = new Uint8Array(wasm.length + 3);
  shifted.set(wasm, 3);
  const sources = [wasm, wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength), shifted.subarray(3)];
  for (const source of sources) {
    const kiln = await load(source);
    assert.equal(kiln.flac.probe(flac).sampleRate, 44100);
  }
});

test('kiln.js に import.meta.url を基準にした URL を書かない(バンドラが kiln.wasm を出力するため、soundkitchen/kiln#11)', async () => {
  const js = await readFile(path.join(root, 'wasm/kiln.js'), 'utf8');
  // Vite や webpack 5 が拾うのは new URL('...', import.meta.url) の形
  assert.doesNotMatch(js, /new\s+URL\s*\([^)]*import\.meta\.url/);
});
