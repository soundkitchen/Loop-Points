import { fileAccessSupported } from './jsonFile';
import { setupTheme } from './theme';

// 入口。保存は File System Access API で保存先に直接書き込むので、この API のあるブラウザ (Chromium 系) でだけ動かす。
// ない場合は案内を出して止める。ES モジュールは途中で止められないので、本体 (main.ts) は使えるときだけ読み込む。
// 操作の部分は、本体が動くまで index.html の CSS で隠しておく。body に付けるクラスで、表示を切り替える
//   ready: 本体が動いた / unsupported: API がない / failed: 本体を読み込めなかった

// 本体が動く前と動かないときに、ドロップしたファイルをブラウザが開いてページから離れないようにする。
// 本体のドロップの処理と重なっても害はない
const hasFiles = (e: DragEvent) => e.dataTransfer?.types.includes('Files') ?? false;
for (const type of ['dragover', 'drop'] as const) {
  addEventListener(type, (e) => {
    if (hasFiles(e)) e.preventDefault();
  });
}

if (fileAccessSupported) {
  import('./main').then(
    () => document.body.classList.add('ready'),
    // デプロイのあとに古いチャンクを取りに行ったときや、通信が切れたとき
    (e) => {
      console.error(e);
      document.body.classList.add('failed');
      setupTheme(() => {});
    },
  );
} else {
  document.body.classList.add('unsupported');
  setupTheme(() => {});
}
