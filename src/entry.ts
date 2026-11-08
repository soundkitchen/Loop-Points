import { fileAccessSupported } from './jsonFile';
import { setupTheme } from './theme';

// 入口。保存は File System Access API で保存先に直接書き込むので、この API のあるブラウザ (Chromium 系) でだけ動かす。
// ない場合は案内を出して止める。ES モジュールは途中で止められないので、本体 (main.ts) は使えるときだけ読み込む
if (fileAccessSupported) {
  void import('./main');
} else {
  document.body.classList.add('unsupported');
  setupTheme(() => {});
}
