import { defineConfig, type Plugin } from 'vite';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { IncomingMessage, ServerResponse } from 'node:http';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
// 音源はプロジェクト直下の sounds/ に置き、ゲームと共有する
const SOUNDS = path.resolve(ROOT, '../../sounds');
// ループポイントの保存先。ゲームもこのファイルを読む
const LOOPS = path.join(SOUNDS, 'loops.json');
const AUDIO_EXT = /\.(mp3|wav|ogg|opus|m4a|aac|flac)$/i;
const AUDIO_TYPE: Record<string, string> = {
  mp3: 'audio/mpeg', wav: 'audio/wav', ogg: 'audio/ogg', opus: 'audio/ogg', m4a: 'audio/mp4', aac: 'audio/aac', flac: 'audio/flac',
};

function sendJson(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage) {
  let body = '';
  for await (const chunk of req) body += chunk;
  return body;
}

async function readLoops(): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await fs.readFile(LOOPS, 'utf8'));
  } catch (e) {
    // まだ一度も保存していなければ空
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return {};
    throw e;
  }
}

// 保存する前に形を確かめる。ファイル名ごとに loopStart < loopEnd (秒) を持つ
function validLoops(v: unknown): v is Record<string, { loopStart: number; loopEnd: number }> {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return false;
  return Object.values(v).every((p) =>
    typeof p === 'object' && p !== null &&
    Number.isFinite(p.loopStart) && Number.isFinite(p.loopEnd) && 0 <= p.loopStart && p.loopStart < p.loopEnd);
}

// 開発サーバーに足す API。音源の一覧と、ループポイントの読み書き
function soundsApi(): Plugin {
  return {
    name: 'sounds-api',
    configureServer(server) {
      server.middlewares.use('/api/sounds', async (_req, res) => {
        try {
          const names = (await fs.readdir(SOUNDS)).filter((n) => AUDIO_EXT.test(n)).sort();
          sendJson(res, 200, names);
        } catch (e) {
          sendJson(res, 500, { error: String(e) });
        }
      });
      // 音源を返す。公開ディレクトリの配信は URL を decodeURI でしか戻さず、& や # を含むファイル名を読めないため、クエリで受け取る
      server.middlewares.use('/api/audio', async (req, res) => {
        const name = new URL(req.url ?? '', 'http://localhost').searchParams.get('name') ?? '';
        // sounds/ 直下の音声ファイルだけ (../ などで外へ出させない)
        if (name !== path.basename(name) || !AUDIO_EXT.test(name)) return sendJson(res, 400, { error: 'invalid name' });
        try {
          const data = await fs.readFile(path.join(SOUNDS, name));
          res.setHeader('Content-Type', AUDIO_TYPE[path.extname(name).slice(1).toLowerCase()]);
          res.end(data);
        } catch (e) {
          sendJson(res, (e as NodeJS.ErrnoException).code === 'ENOENT' ? 404 : 500, { error: String(e) });
        }
      });
      server.middlewares.use('/api/loops', async (req, res) => {
        try {
          if (req.method === 'PUT') {
            const loops: unknown = JSON.parse(await readBody(req));
            if (!validLoops(loops)) return sendJson(res, 400, { error: 'invalid loops' });
            // 受け取った音源の項目だけを今の loops.json に重ねる。古いタブから保存しても、ほかの音源の値を消さない
            const merged = { ...(await readLoops()), ...loops };
            // 差分が読みやすいよう、ファイル名の順に並べて書く
            const sorted = Object.fromEntries(Object.keys(merged).sort().map((k) => [k, merged[k]]));
            await fs.writeFile(LOOPS, JSON.stringify(sorted, null, 2) + '\n');
            return sendJson(res, 200, { ok: true });
          }
          sendJson(res, 200, await readLoops());
        } catch (e) {
          sendJson(res, 500, { error: String(e) });
        }
      });
    },
  };
}

export default defineConfig({
  // 音源は /api/audio で返すので、公開ディレクトリは使わない
  publicDir: false,
  plugins: [soundsApi()],
  server: {
    port: 5175,   // 001 (5173)・002 (5174) と同時に起動できるようにずらす
  },
});
