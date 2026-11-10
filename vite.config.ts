import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    watch: {
      // 取ってきた Zig と Zig のビルドのキャッシュは数万のファイルがあり、見張ると起動が遅くなる。
      // kiln/zig-out/ は見張り、npm run kiln:build でビルドし直した wasm を開発サーバーに反映する
      ignored: ['**/.zig/**', '**/kiln/.zig-cache/**'],
    },
  },
});
