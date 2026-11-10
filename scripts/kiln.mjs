// kiln (kiln/) の wasm をビルドし、テストする。npm run dev / build の前に build を呼ぶ。
//   node scripts/kiln.mjs build   kiln/zig-out/wasm/kiln.wasm を作る
//   node scripts/kiln.mjs test    Zig のテスト、kiln.js の実行時のテスト、kiln.d.ts の型の検査
// Zig は PATH にある 0.17.1 を使う (手元は direnv で $HOME/Zig/0.17)。なければ公式のアーカイブを .zig/ に取ってきて、
// sha256 を確かめてから使う (Workers Builds には Zig がないため)
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ZIG_VERSION = '0.17.1';
// https://ziglang.org/download/index.json の 0.17.1 の値。バージョンを上げるときは、ここと kiln/build.zig.zon を一緒に直す
const ZIG_ARCHIVES = {
  'x86_64-linux': '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a',
  'aarch64-linux': 'a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795',
  'x86_64-macos': '9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7',
  'aarch64-macos': '75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d',
};

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const kilnDir = path.join(root, 'kiln');
const zigHome = path.join(root, '.zig');

function run(cmd, args, cwd = root) {
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit' });
  if (r.error) throw r.error;
  if (r.status !== 0) process.exit(r.status ?? 1);
}

function pathZigVersion() {
  const r = spawnSync('zig', ['version'], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout.trim() : null;
}

async function downloadZig() {
  const arch = { x64: 'x86_64', arm64: 'aarch64' }[process.arch];
  const os = { linux: 'linux', darwin: 'macos' }[process.platform];
  const key = `${arch}-${os}`;
  const sha256 = ZIG_ARCHIVES[key];
  if (!sha256) throw new Error(`Zig ${ZIG_VERSION} for ${process.platform}/${process.arch} is not listed in scripts/kiln.mjs`);
  const name = `zig-${key}-${ZIG_VERSION}`;
  const zig = path.join(zigHome, name, 'zig');
  if (existsSync(zig)) return zig;

  const url = `https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz`;
  console.log(`Downloading ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to download Zig: ${res.status} ${res.statusText}`);
  const archive = Buffer.from(await res.arrayBuffer());
  const actual = createHash('sha256').update(archive).digest('hex');
  if (actual !== sha256) throw new Error(`Zig archive sha256 mismatch: expected ${sha256}, got ${actual}`);

  mkdirSync(zigHome, { recursive: true });
  const file = path.join(zigHome, `${name}.tar.xz`);
  writeFileSync(file, archive);
  run('tar', ['-xJf', file, '-C', zigHome]);
  rmSync(file);
  return zig;
}

async function findZig() {
  const version = pathZigVersion();
  if (version === ZIG_VERSION) return 'zig';
  if (version) console.log(`zig on PATH is ${version}; using Zig ${ZIG_VERSION} in .zig/`);
  return downloadZig();
}

const command = process.argv[2];
if (command === 'build') {
  run(await findZig(), ['build', 'wasm'], kilnDir);
} else if (command === 'test') {
  run(await findZig(), ['build', 'test'], kilnDir);
  run(process.execPath, ['--test', 'wasm/test/*.test.mjs'], kilnDir);
  for (const env of ['dom', 'worker', 'es']) {
    run(process.execPath, [path.join(root, 'node_modules/typescript/bin/tsc'), '-p', `wasm/types/tsconfig.${env}.json`], kilnDir);
  }
} else {
  console.error('usage: node scripts/kiln.mjs <build|test>');
  process.exit(2);
}
