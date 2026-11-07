// 最初の描画の前にテーマを決めて、ちらつきを防ぐ。選択の扱いは src/theme.ts と合わせる
(() => {
  let choice = null;
  try { choice = localStorage.getItem('loop-points-theme'); } catch { /* 読めなければシステムに合わせる */ }
  document.documentElement.dataset.theme = choice === 'light' || choice === 'dark' ? choice
    : matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
})();
