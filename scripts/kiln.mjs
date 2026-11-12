// kiln (kiln/) の wasm をビルドし、テストする。
//   node scripts/kiln.mjs build       kiln/zig-out/kiln.wasm を作る (npm run dev / build の前に動く)
//   node scripts/kiln.mjs test        Zig のテスト、kiln.ts の実行時のテスト、kiln.ts の型の検査
//   node scripts/kiln.mjs check-dist  dist/ に .wasm のファイルがないことを確かめる (npm run build の後に動く)
// Zig は PATH にある 0.17.1 を使う (手元は direnv で $HOME/Zig/0.17)。なければ公式のアーカイブを .zig/ に取ってきて、
// sha256 を確かめてから使う (Workers Builds には Zig がないため)
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ZIG_VERSION = '0.17.1';
// https://ziglang.org/download/index.json の 0.17.1 の値。バージョンを上げるときは、ここと kiln/build.zig.zon を一緒に直す。
// どこから取ってきても、この sha256 と一致することを確かめるので、ミラーの中身を信用しなくてよい
const ZIG_ARCHIVES = {
  'x86_64-linux': '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a',
  'aarch64-linux': 'a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795',
  'x86_64-macos': '9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7',
  'aarch64-macos': '75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d',
};
// Zig は、自動化した環境ではコミュニティのミラーを順に試し、最後に ziglang.org を使うよう求めている
// (https://ziglang.org/download/community-mirrors/)
const MIRROR_LIST = 'https://ziglang.org/download/community-mirrors.txt';
const TIMEOUT_MS = 120_000;   // 1 回の取得 (本体を読み終えるまで)。止まったまま Workers Builds のタイムアウトまで待たない

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

async function fetchBytes(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return Buffer.from(await res.arrayBuffer());
}

async function mirrors() {
  try {
    const text = (await fetchBytes(MIRROR_LIST)).toString('utf8');
    const list = text.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('https://'));
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  } catch (e) {
    console.log(`Could not get the Zig mirror list (${e.message}); using ziglang.org`);
    return [];
  }
}

async function downloadArchive(file, sha256) {
  const urls = [...(await mirrors()).map((m) => `${m.replace(/\/$/, '')}/${file}?source=loop-points`),
    `https://ziglang.org/download/${ZIG_VERSION}/${file}`];
  for (const url of urls) {
    try {
      console.log(`Downloading ${url}`);
      const archive = await fetchBytes(url);
      const actual = createHash('sha256').update(archive).digest('hex');
      if (actual === sha256) return archive;
      console.log(`  sha256 mismatch (${actual})`);
    } catch (e) {
      console.log(`  failed: ${e.message}`);
    }
  }
  throw new Error(`Could not download ${file} from any mirror or ziglang.org`);
}

// tar で展開する。xz コマンドがなく tar が失敗したら、Python の tarfile で展開する (Python は xz を自前で読める)
function extract(archive, dest) {
  const tar = spawnSync('tar', ['-xJf', archive, '-C', dest], { stdio: 'inherit' });
  if (tar.status === 0) return;
  console.log('tar failed; extracting with python3');
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dest, { recursive: true });
  // 失敗は投げて、呼ぶ側の finally で一時ディレクトリを消す (run は process.exit するので finally が動かない)
  const py = spawnSync('python3', ['-c', 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2])', archive, dest], { stdio: 'inherit' });
  if (py.status !== 0) throw new Error(`Could not extract ${path.basename(archive)} (python3: ${py.error?.message ?? `exit ${py.status}`})`);
}

async function downloadZig() {
  const arch = { x64: 'x86_64', arm64: 'aarch64' }[process.arch];
  const os = { linux: 'linux', darwin: 'macos' }[process.platform];
  const key = `${arch}-${os}`;
  const sha256 = ZIG_ARCHIVES[key];
  if (!sha256) throw new Error(`Zig ${ZIG_VERSION} for ${process.platform}/${process.arch} is not listed in scripts/kiln.mjs`);
  const name = `zig-${key}-${ZIG_VERSION}`;
  const dir = path.join(zigHome, name);
  // 展開し終えたものだけをこの名前に移すので、あれば使える
  if (existsSync(dir)) return path.join(dir, 'zig');

  const archive = await downloadArchive(`${name}.tar.xz`, sha256);
  const tmp = path.join(zigHome, `tmp-${process.pid}`);
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(tmp, { recursive: true });
  try {
    const file = path.join(tmp, `${name}.tar.xz`);
    writeFileSync(file, archive);
    const out = path.join(tmp, 'out');
    mkdirSync(out);
    extract(file, out);
    renameSync(path.join(out, name), dir);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  return path.join(dir, 'zig');
}

async function findZig() {
  const version = pathZigVersion();
  if (version === ZIG_VERSION) return 'zig';
  if (version) console.log(`zig on PATH is ${version}; using Zig ${ZIG_VERSION} in .zig/`);
  return downloadZig();
}

// kiln.wasm は、最初の音源を開くときに読むチャンクに埋め込む。別のファイルとして出ると、CSP の connect-src 'none' で読めず、
// 元のサンプルレートを調べられなくなり (出力の機器のレートに変換して開く)、クロップの書き出しもできなくなる
function checkDist() {
  const found = readdirSync(path.join(root, 'dist'), { recursive: true }).filter((f) => String(f).endsWith('.wasm'));
  if (found.length) {
    console.error(`dist/ has .wasm files (${found.join(', ')}). kiln.wasm must be inlined into the kiln chunk.`);
    process.exit(1);
  }
}

const command = process.argv[2];
if (command === 'build') {
  run(await findZig(), ['build', 'wasm'], kilnDir);
} else if (command === 'test') {
  run(await findZig(), ['build', 'test'], kilnDir);
  run(process.execPath, ['--test', 'wasm/test/*.test.mjs'], kilnDir);
  // kiln/wasm の型の検査(kiln.ts と、誤った使い方の検査の test/types.ts)。Loop Points の設定に、型を消すだけで動く
  // 書き方の制約(erasableSyntaxOnly)を足したもの。Loop Points の tsconfig.json の include にも kiln/wasm を入れてあり、
  // npm run build でも確かめる
  run(process.execPath, [path.join(root, 'node_modules/typescript/bin/tsc'), '-p', 'kiln/wasm/tsconfig.json']);
} else if (command === 'check-dist') {
  checkDist();
} else {
  console.error('usage: node scripts/kiln.mjs <build|test|check-dist>');
  process.exit(2);
}
