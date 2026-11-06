import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    port: 5175,   // 001 (5173)・002 (5174) と同時に起動できるようにずらす
  },
});
