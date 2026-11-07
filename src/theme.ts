// 配色の切り替え。選択はブラウザに保存する。最初の描画の前の決定は public/theme-init.js が行う
type ThemeChoice = 'system' | 'light' | 'dark';

const STORAGE_KEY = 'loop-points-theme';

function readChoice(): ThemeChoice {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  } catch {
    return 'system';   // ストレージを使えない環境では保存せずに動かす
  }
}

function saveChoice(choice: ThemeChoice) {
  try {
    localStorage.setItem(STORAGE_KEY, choice);
  } catch {
    // 保存できなくても、開いている間の切り替えはできる
  }
}

// onChange は配色が決まるたびに呼ぶ。data-theme を変えたあとなので、新しい CSS 変数を読める
export function setupTheme(onChange: () => void) {
  const media = matchMedia('(prefers-color-scheme: dark)');
  const buttons = [...document.querySelectorAll<HTMLButtonElement>('[data-theme-choice]')];
  let choice = readChoice();

  const apply = () => {
    document.documentElement.dataset.theme = choice === 'system' ? (media.matches ? 'dark' : 'light') : choice;
    for (const b of buttons) b.setAttribute('aria-pressed', String(b.dataset.themeChoice === choice));
    onChange();
  };

  for (const b of buttons) {
    b.addEventListener('click', () => {
      choice = b.dataset.themeChoice as ThemeChoice;
      saveChoice(choice);
      apply();
    });
  }
  // システムの設定が変わったら、システムを選んでいるときだけ追従する
  media.addEventListener('change', () => {
    if (choice === 'system') apply();
  });
  // 別のタブでの選択に合わせる。key が null なのはストレージ全体が消されたとき
  addEventListener('storage', (e) => {
    if (e.key !== STORAGE_KEY && e.key !== null) return;
    choice = readChoice();
    apply();
  });
  apply();
}
