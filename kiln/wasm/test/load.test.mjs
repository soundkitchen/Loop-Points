// SPDX-License-Identifier: MIT
// kiln.js の load の実行時テスト。zig build でできた zig-out/wasm/ を読む。
// リポジトリ直下で `zig build && node --test 'wasm/test/*.test.mjs'`(Node 22 以降)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const out = path.join(root, 'zig-out/wasm');
const { load } = await import(path.join(out, 'kiln.js'));
const wasm = await readFile(path.join(out, 'kiln.wasm'));
const flac = await readFile(path.join(root, 'testdata/s16-stereo.flac'));

test('URL でもバイト列でもない値は、TypeError で reject する', async () => {
  for (const source of [undefined, null, 1, {}, new Blob([wasm]), new Response(wasm), Promise.resolve(wasm)]) {
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

test('URL(文字列か、href を持つもの)で読み込める。404 はエラーにする', async () => {
  const server = createServer((req, res) => {
    if (req.url === '/kiln.wasm') {
      res.writeHead(200, { 'content-type': 'application/wasm' });
      res.end(wasm);
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    assert.equal((await load(`${base}/kiln.wasm`)).flac.probe(flac).channels, 2);
    assert.equal((await load(new URL('/kiln.wasm', base))).flac.probe(flac).channels, 2);
    await assert.rejects(load(`${base}/missing.wasm`), /failed to fetch .* 404/);
  } finally {
    server.close();
  }
});

test('kiln.js に import.meta.url を基準にした URL を書かない(バンドラが kiln.wasm を出力するため、soundkitchen/kiln#11)', async () => {
  const js = await readFile(path.join(out, 'kiln.js'), 'utf8');
  // Vite や webpack 5 が拾うのは new URL('...', import.meta.url) の形
  assert.doesNotMatch(js, /new\s+URL\s*\([^)]*import\.meta\.url/);
});
